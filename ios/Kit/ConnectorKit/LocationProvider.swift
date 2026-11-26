import Foundation

/// Source of GPS / heading. `CoreLocationProvider` is the real one; `InMemoryLocationProvider` for tests.
public protocol LocationProvider: Sendable {
    func permission() async -> PermissionState
    func requestAccess() async throws -> Bool
    func currentFix() async throws -> LocationFix
}

public actor InMemoryLocationProvider: LocationProvider {
    private var state: PermissionState
    private var fix: LocationFix?
    private let grantOnRequest: Bool

    public init(
        permission: PermissionState = .authorized,
        fix: LocationFix? = LocationFix(latitude: 37.7749, longitude: -122.4194, altitudeMeters: 16, horizontalAccuracyMeters: 8),
        grantOnRequest: Bool = true
    ) {
        self.state = permission
        self.fix = fix
        self.grantOnRequest = grantOnRequest
    }

    public func permission() -> PermissionState { state }

    public func requestAccess() -> Bool {
        if state == .notDetermined { state = grantOnRequest ? .authorized : .denied }
        return state == .authorized
    }

    public func currentFix() throws -> LocationFix {
        guard state == .authorized else {
            throw ConnectorError.permissionDenied(
                "Location access has not been granted. Connect Location in You → Connectors, then allow Location for Applebot in Settings."
            )
        }
        guard let fix else {
            throw ConnectorError.unexpectedResponse("No GPS fix is available yet. Try again outdoors with a clear sky.")
        }
        return fix
    }

    public func setFix(_ fix: LocationFix?) { self.fix = fix }
    public func setPermission(_ state: PermissionState) { self.state = state }
}

/// On-device waypoints and breadcrumb trail.
public protocol TrailStore: Sendable {
    func listWaypoints() async -> [WaypointInfo]
    func upsertWaypoint(_ waypoint: WaypointInfo) async
    func deleteWaypoint(id: UUID) async
    func breadcrumbs() async -> [BreadcrumbPoint]
    func appendBreadcrumb(_ point: BreadcrumbPoint) async
    func clearBreadcrumbs() async
}

public actor InMemoryTrailStore: TrailStore {
    private var waypoints: [WaypointInfo]
    private var crumbs: [BreadcrumbPoint]
    public static let maxBreadcrumbs = 2_000

    public init(waypoints: [WaypointInfo] = [], breadcrumbs: [BreadcrumbPoint] = []) {
        self.waypoints = waypoints
        self.crumbs = breadcrumbs
    }

    public func listWaypoints() -> [WaypointInfo] {
        waypoints.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func upsertWaypoint(_ waypoint: WaypointInfo) {
        if let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) {
            waypoints[index] = waypoint
        } else if let byName = waypoints.firstIndex(where: {
            $0.name.caseInsensitiveCompare(waypoint.name) == .orderedSame
        }) {
            var copy = waypoint
            copy.id = waypoints[byName].id
            waypoints[byName] = copy
        } else {
            waypoints.append(waypoint)
        }
    }

    public func deleteWaypoint(id: UUID) {
        waypoints.removeAll { $0.id == id }
    }

    public func breadcrumbs() -> [BreadcrumbPoint] { crumbs }

    public func appendBreadcrumb(_ point: BreadcrumbPoint) {
        if let last = crumbs.last {
            let meters = GeoMath.distanceMeters(
                fromLat: last.latitude, fromLon: last.longitude,
                toLat: point.latitude, toLon: point.longitude
            )
            // Ignore jitter under ~8 m.
            if meters < 8 { return }
        }
        crumbs.append(point)
        if crumbs.count > Self.maxBreadcrumbs {
            crumbs.removeFirst(crumbs.count - Self.maxBreadcrumbs)
        }
    }

    public func clearBreadcrumbs() { crumbs = [] }
}

/// Persistence for offline map pack metadata and tile bytes.
public protocol OfflineMapStore: Sendable {
    func packs() async -> [OfflineMapPackInfo]
    func savePack(_ pack: OfflineMapPackInfo) async
    func deletePack(id: UUID) async throws
    func hasTile(packID: UUID, z: Int, x: Int, y: Int) async -> Bool
    func loadTile(packID: UUID, z: Int, x: Int, y: Int) async -> Data?
    func saveTile(packID: UUID, z: Int, x: Int, y: Int, data: Data) async throws
}

public actor InMemoryOfflineMapStore: OfflineMapStore {
    private var packsByID: [UUID: OfflineMapPackInfo] = [:]
    private var tiles: [String: Data] = [:]

    public init(packs: [OfflineMapPackInfo] = []) {
        for pack in packs { packsByID[pack.id] = pack }
    }

    public func packs() -> [OfflineMapPackInfo] {
        packsByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func savePack(_ pack: OfflineMapPackInfo) { packsByID[pack.id] = pack }

    public func deletePack(id: UUID) {
        packsByID.removeValue(forKey: id)
        let prefix = "\(id.uuidString)/"
        tiles = tiles.filter { !$0.key.hasPrefix(prefix) }
    }

    public func hasTile(packID: UUID, z: Int, x: Int, y: Int) -> Bool {
        tiles[key(packID, z, x, y)] != nil
    }

    public func loadTile(packID: UUID, z: Int, x: Int, y: Int) -> Data? {
        tiles[key(packID, z, x, y)]
    }

    public func saveTile(packID: UUID, z: Int, x: Int, y: Int, data: Data) {
        tiles[key(packID, z, x, y)] = data
        if var pack = packsByID[packID] {
            pack.tileCount = tiles.keys.filter { $0.hasPrefix("\(packID.uuidString)/") }.count
            pack.byteSize = tiles
                .filter { $0.key.hasPrefix("\(packID.uuidString)/") }
                .map(\.value.count)
                .reduce(0, +)
            packsByID[packID] = pack
        }
    }

    private func key(_ packID: UUID, _ z: Int, _ x: Int, _ y: Int) -> String {
        "\(packID.uuidString)/\(z)/\(x)/\(y)"
    }
}

/// Optional weather cache for offline answers.
public protocol WeatherCacheStore: Sendable {
    func load() async -> CachedWeather?
    func save(_ cached: CachedWeather) async
    func clear() async
}

public actor InMemoryWeatherCacheStore: WeatherCacheStore {
    private var cached: CachedWeather?

    public init(cached: CachedWeather? = nil) { self.cached = cached }

    public func load() -> CachedWeather? { cached }
    public func save(_ cached: CachedWeather) { self.cached = cached }
    public func clear() { cached = nil }
}
