import Foundation
import LLMKit

/// On-device GPS, waypoints and breadcrumbs for wilderness / no-signal navigation.
///
/// Location never leaves the device. Map tile downloads are handled by `OfflineMapDownloader`
/// (network only while downloading a pack).
public struct LocationConnector: Connector {
    public let id = "location"
    public let displayName = "Location"
    public let summary = "GPS position, compass bearing to waypoints, and breadcrumb trail — works offline."
    public let symbolName = "location.north.line"
    public let dataNote = "Reads GPS on this iPhone only. Coordinates stay on the device and are never uploaded. Offline map packs use OpenTopoMap tiles only when you download a region."
    public let hasAccount = false
    public var usesNetwork: Bool { false }

    public static let maxWaypoints = 40

    private let provider: any LocationProvider
    private let trail: any TrailStore
    private let maps: any OfflineMapStore
    private let imperial: Bool
    private let clock: @Sendable () -> Date

    public init(
        provider: any LocationProvider,
        trail: any TrailStore = InMemoryTrailStore(),
        maps: any OfflineMapStore = InMemoryOfflineMapStore(),
        imperial: Bool = Locale.current.measurementSystem == .us,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.trail = trail
        self.maps = maps
        self.imperial = imperial
        self.clock = clock
    }

    public func status() async -> ConnectorStatus {
        switch await provider.permission() {
        case .authorized:
            return .connected(account: nil)
        case .denied, .restricted:
            return .notConnected
        case .notDetermined:
            return .notConnected
        }
    }

    public func connect() async throws {
        let granted = try await provider.requestAccess()
        guard granted else {
            throw ConnectorError.permissionDenied(
                "Location access was denied. Allow Location for Applebot in the Settings app."
            )
        }
    }

    public func disconnect() async {}

    public func tools() -> [ToolSpec] {
        [currentTool, listWaypointsTool, addWaypointTool, bearingTool, breadcrumbsTool, listMapsTool]
    }

    // MARK: Tools

    private var currentTool: ToolSpec {
        let provider = self.provider
        let trail = self.trail
        let imperial = self.imperial
        let clock = self.clock
        return ToolSpec(
            name: "location_current",
            description: "Get the user's current GPS coordinates, accuracy, altitude and course. Use when they ask where they are, for coordinates, if they are lost, or need a position for navigation. Works offline with GPS.",
            parameters: [
                ToolParameter(
                    "drop_breadcrumb",
                    "Set to 'yes' to also append this fix to the on-device breadcrumb trail.",
                    required: false
                ),
            ],
            label: "Reading GPS",
            handler: { arguments in
                let fix = try await provider.currentFix()
                if (arguments.string("drop_breadcrumb") ?? "").lowercased().hasPrefix("y") {
                    await trail.appendBreadcrumb(
                        BreadcrumbPoint(latitude: fix.latitude, longitude: fix.longitude, timestamp: clock())
                    )
                }
                return Self.renderFix(fix, imperial: imperial, calendar: .current)
            }
        )
    }

    private var listWaypointsTool: ToolSpec {
        let trail = self.trail
        return ToolSpec(
            name: "location_list_waypoints",
            description: "List saved waypoints (car, camp, trailhead) stored on this iPhone for offline navigation.",
            parameters: [],
            label: "Listing waypoints",
            handler: { _ in
                let rows = await trail.listWaypoints()
                guard !rows.isEmpty else {
                    return "No waypoints saved yet. Ask the user for a name and coordinates, or save their current GPS as a waypoint."
                }
                var lines = ["Waypoints (\(rows.count)):"]
                for row in rows.prefix(Self.maxWaypoints) {
                    lines.append("- \(row.summaryLine)")
                }
                return lines.joined(separator: "\n")
            }
        )
    }

    private var addWaypointTool: ToolSpec {
        let provider = self.provider
        let trail = self.trail
        let clock = self.clock
        return ToolSpec(
            name: "location_add_waypoint",
            description: "Save a named waypoint on this iPhone. Pass latitude and longitude, or omit them to use the current GPS fix.",
            parameters: [
                ToolParameter("name", "Short name such as 'Car', 'Camp', or 'Trailhead'."),
                ToolParameter("latitude", "Decimal latitude. Optional when using the current GPS.", required: false),
                ToolParameter("longitude", "Decimal longitude. Optional when using the current GPS.", required: false),
                ToolParameter("notes", "Optional short note.", required: false),
            ],
            label: "Saving waypoint",
            requiresApproval: true,
            approval: { args in
                let name = args.string("name") ?? "Waypoint"
                let detail: String
                if let lat = args.string("latitude"), let lon = args.string("longitude") {
                    detail = "Save waypoint \"\(name)\" at \(lat), \(lon)."
                } else {
                    detail = "Save waypoint \"\(name)\" at the current GPS position."
                }
                return ApprovalRequest(
                    toolName: "location_add_waypoint",
                    title: "Save waypoint",
                    detail: detail,
                    confirmLabel: "Save"
                )
            },
            handler: { arguments in
                guard let name = arguments.string("name"), !name.isEmpty else {
                    throw ConnectorError.invalidArgument("A waypoint name is required, for example 'Car'.")
                }
                let existing = await trail.listWaypoints()
                if existing.count >= Self.maxWaypoints,
                   !existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    throw ConnectorError.invalidArgument(
                        "You already have \(Self.maxWaypoints) waypoints. Delete one first."
                    )
                }
                let lat: Double
                let lon: Double
                if let latText = arguments.string("latitude"), let lonText = arguments.string("longitude"),
                   let parsedLat = Double(latText), let parsedLon = Double(lonText) {
                    guard (-90...90).contains(parsedLat), (-180...180).contains(parsedLon) else {
                        throw ConnectorError.invalidArgument("Latitude must be −90…90 and longitude −180…180.")
                    }
                    lat = parsedLat
                    lon = parsedLon
                } else {
                    let fix = try await provider.currentFix()
                    lat = fix.latitude
                    lon = fix.longitude
                }
                let now = clock()
                let waypoint = WaypointInfo(
                    name: name,
                    latitude: lat,
                    longitude: lon,
                    notes: arguments.string("notes") ?? "",
                    createdAt: now,
                    updatedAt: now
                )
                await trail.upsertWaypoint(waypoint)
                return "Saved waypoint \(waypoint.summaryLine)."
            }
        )
    }

    private var bearingTool: ToolSpec {
        let provider = self.provider
        let trail = self.trail
        let imperial = self.imperial
        return ToolSpec(
            name: "location_bearing",
            description: "Compute distance and compass bearing from the current GPS fix to a saved waypoint (by name) or to given coordinates. Works fully offline.",
            parameters: [
                ToolParameter("waypoint", "Name of a saved waypoint, for example 'Car'.", required: false),
                ToolParameter("latitude", "Target latitude when not using a waypoint name.", required: false),
                ToolParameter("longitude", "Target longitude when not using a waypoint name.", required: false),
            ],
            label: "Computing bearing",
            handler: { arguments in
                let fix = try await provider.currentFix()
                let targetLat: Double
                let targetLon: Double
                let label: String
                if let name = arguments.string("waypoint") {
                    let rows = await trail.listWaypoints()
                    guard let hit = rows.first(where: {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame
                            || $0.name.lowercased().contains(name.lowercased())
                    }) else {
                        throw ConnectorError.invalidArgument(
                            "No waypoint named \"\(name)\". Save one first or pass latitude and longitude."
                        )
                    }
                    targetLat = hit.latitude
                    targetLon = hit.longitude
                    label = hit.name
                } else if let latText = arguments.string("latitude"), let lonText = arguments.string("longitude"),
                          let parsedLat = Double(latText), let parsedLon = Double(lonText) {
                    targetLat = parsedLat
                    targetLon = parsedLon
                    label = "target"
                } else {
                    throw ConnectorError.invalidArgument(
                        "Pass a waypoint name, or both latitude and longitude."
                    )
                }
                let meters = GeoMath.distanceMeters(
                    fromLat: fix.latitude, fromLon: fix.longitude,
                    toLat: targetLat, toLon: targetLon
                )
                let bearing = GeoMath.bearingDegrees(
                    fromLat: fix.latitude, fromLon: fix.longitude,
                    toLat: targetLat, toLon: targetLon
                )
                let card = GeoMath.cardinal(forBearingDegrees: bearing)
                var lines = [
                    "From \(fix.coordinateLine) to \(label):",
                    "- Distance \(GeoMath.formatDistanceMeters(meters, imperial: imperial))",
                    "- Bearing \(LiveData.number(bearing))° (\(card))",
                ]
                if let accuracy = fix.horizontalAccuracyMeters, accuracy > 0 {
                    lines.append("- GPS accuracy ±\(LiveData.number(accuracy)) m")
                }
                lines.append("Use a compass or the Trail tab map; this is true north, not magnetic.")
                return lines.joined(separator: "\n")
            }
        )
    }

    private var breadcrumbsTool: ToolSpec {
        let trail = self.trail
        let imperial = self.imperial
        return ToolSpec(
            name: "location_breadcrumbs",
            description: "Summarise the on-device breadcrumb trail (how far walked, start and latest points). Works offline.",
            parameters: [
                ToolParameter(
                    "clear",
                    "Set to 'yes' to clear the trail after summarising (requires approval).",
                    required: false
                ),
            ],
            label: "Reading trail",
            requiresApproval: false,
            handler: { arguments in
                let wantsClear = (arguments.string("clear") ?? "").lowercased().hasPrefix("y")
                if wantsClear {
                    // Clearing is a write; enforce approval via a dedicated path below when model asks.
                    // For safety, refuse without going through the approved clear tool pattern:
                    throw ConnectorError.invalidArgument(
                        "To clear the trail, ask the user to clear it in the Trail tab (Clear trail)."
                    )
                }
                let crumbs = await trail.breadcrumbs()
                guard let first = crumbs.first, let last = crumbs.last else {
                    return "No breadcrumb trail yet. Ask to drop a breadcrumb with location_current, or enable trail recording in the Trail tab."
                }
                var path = 0.0
                if crumbs.count > 1 {
                    for index in 1..<crumbs.count {
                        path += GeoMath.distanceMeters(
                            fromLat: crumbs[index - 1].latitude, fromLon: crumbs[index - 1].longitude,
                            toLat: crumbs[index].latitude, toLon: crumbs[index].longitude
                        )
                    }
                }
                return [
                    "Breadcrumb trail: \(crumbs.count) points.",
                    "- Start \(LocationFix(latitude: first.latitude, longitude: first.longitude).coordinateLine) at \(DateInput.format(first.timestamp, calendar: .current))",
                    "- Latest \(LocationFix(latitude: last.latitude, longitude: last.longitude).coordinateLine) at \(DateInput.format(last.timestamp, calendar: .current))",
                    "- Path length about \(GeoMath.formatDistanceMeters(path, imperial: imperial))",
                ].joined(separator: "\n")
            }
        )
    }

    private var listMapsTool: ToolSpec {
        let maps = self.maps
        return ToolSpec(
            name: "location_list_map_packs",
            description: "List offline map packs downloaded on this iPhone for wilderness navigation without signal.",
            parameters: [],
            label: "Listing offline maps",
            handler: { _ in
                let packs = await maps.packs()
                guard !packs.isEmpty else {
                    return "No offline map packs yet. Download a region in the Trail tab while you have signal."
                }
                var lines = ["Offline map packs (\(packs.count)):"]
                for pack in packs {
                    lines.append(
                        "- \(pack.name) [\(pack.status.rawValue)] \(pack.boundsLine); \(pack.sizeLine)"
                    )
                }
                lines.append("Tiles are OpenTopoMap (CC-BY-SA); attribution required when shown on a map.")
                return lines.joined(separator: "\n")
            }
        )
    }

    // MARK: Render

    static func renderFix(_ fix: LocationFix, imperial: Bool, calendar: Calendar) -> String {
        var lines = [
            "Current position \(fix.coordinateLine).",
            "As of \(DateInput.format(fix.timestamp, calendar: calendar)).",
        ]
        if let accuracy = fix.horizontalAccuracyMeters {
            lines.append("Horizontal accuracy ±\(LiveData.number(accuracy)) m.")
        }
        if let altitude = fix.altitudeMeters {
            let text = imperial
                ? "\(LiveData.number(altitude * 3.28084)) ft"
                : "\(LiveData.number(altitude)) m"
            lines.append("Altitude \(text).")
        }
        if let course = fix.courseDegrees, course >= 0 {
            lines.append(
                "Course \(LiveData.number(course))° (\(GeoMath.cardinal(forBearingDegrees: course)))."
            )
        }
        if let speed = fix.speedMetersPerSecond, speed >= 0 {
            let text = imperial
                ? "\(LiveData.number(speed * 2.23694, decimals: 1)) mph"
                : "\(LiveData.number(speed * 3.6, decimals: 1)) km/h"
            lines.append("Speed \(text).")
        }
        lines.append("GPS works without cell signal; maps and live weather need a downloaded pack or cache.")
        return lines.joined(separator: "\n")
    }
}
