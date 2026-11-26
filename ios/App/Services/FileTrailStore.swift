import Foundation
import ConnectorKit

/// JSON-backed waypoints + breadcrumbs under Application Support (profile-scoped).
actor FileTrailStore: TrailStore {
    private let directory: URL
    private var waypoints: [WaypointInfo] = []
    private var crumbs: [BreadcrumbPoint] = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL) {
        self.directory = directory
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        waypoints = Self.load([WaypointInfo].self, from: directory.appendingPathComponent("waypoints.json"), decoder: decoder) ?? []
        crumbs = Self.load([BreadcrumbPoint].self, from: directory.appendingPathComponent("breadcrumbs.json"), decoder: decoder) ?? []
    }

    func listWaypoints() -> [WaypointInfo] {
        waypoints.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func upsertWaypoint(_ waypoint: WaypointInfo) {
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
        persistWaypoints()
    }

    func deleteWaypoint(id: UUID) {
        waypoints.removeAll { $0.id == id }
        persistWaypoints()
    }

    func breadcrumbs() -> [BreadcrumbPoint] { crumbs }

    func appendBreadcrumb(_ point: BreadcrumbPoint) {
        if let last = crumbs.last {
            let meters = GeoMath.distanceMeters(
                fromLat: last.latitude, fromLon: last.longitude,
                toLat: point.latitude, toLon: point.longitude
            )
            if meters < 8 { return }
        }
        crumbs.append(point)
        if crumbs.count > InMemoryTrailStore.maxBreadcrumbs {
            crumbs.removeFirst(crumbs.count - InMemoryTrailStore.maxBreadcrumbs)
        }
        persistBreadcrumbs()
    }

    func clearBreadcrumbs() {
        crumbs = []
        persistBreadcrumbs()
    }

    private func persistWaypoints() {
        Self.save(waypoints, to: directory.appendingPathComponent("waypoints.json"), encoder: encoder)
    }

    private func persistBreadcrumbs() {
        Self.save(crumbs, to: directory.appendingPathComponent("breadcrumbs.json"), encoder: encoder)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
