import Foundation

/// One GPS / Core Location fix summarised for tools and the Trail UI.
public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitudeMeters: Double?
    public var horizontalAccuracyMeters: Double?
    public var courseDegrees: Double?
    public var speedMetersPerSecond: Double?
    public var timestamp: Date

    public init(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double? = nil,
        horizontalAccuracyMeters: Double? = nil,
        courseDegrees: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        timestamp: Date = Date()
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.courseDegrees = courseDegrees
        self.speedMetersPerSecond = speedMetersPerSecond
        self.timestamp = timestamp
    }

    public var coordinateLine: String {
        let latHem = latitude >= 0 ? "N" : "S"
        let lonHem = longitude >= 0 ? "E" : "W"
        return "\(LiveData.number(abs(latitude), decimals: 5))°\(latHem), "
            + "\(LiveData.number(abs(longitude), decimals: 5))°\(lonHem)"
    }
}

/// A saved place (car, camp, trailhead) for offline bearing navigation.
public struct WaypointInfo: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latitude = latitude
        self.longitude = longitude
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var summaryLine: String {
        var line = "\(name) @ \(LocationFix(latitude: latitude, longitude: longitude).coordinateLine)"
        if !notes.isEmpty { line += " — \(notes)" }
        return line
    }
}

/// One point on the on-device breadcrumb trail.
public struct BreadcrumbPoint: Sendable, Equatable, Codable {
    public var latitude: Double
    public var longitude: Double
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, timestamp: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }
}

/// Status of a downloaded offline map region.
public enum OfflineMapPackStatus: String, Sendable, Equatable, Codable, CaseIterable {
    case empty
    case downloading
    case ready
    case failed
}

/// Metadata for an offline map pack (tiles live on disk; this is the index).
public struct OfflineMapPackInfo: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double
    public var minZoom: Int
    public var maxZoom: Int
    public var tileCount: Int
    public var byteSize: Int
    public var status: OfflineMapPackStatus
    public var errorMessage: String?
    public var updatedAt: Date

    public static let defaultMinZoom = 8
    public static let defaultMaxZoom = 13
    /// Soft cap so a pack stays phone-friendly (~ tens of MB, not gigabytes).
    public static let maxTilesPerPack = 2_500

    public init(
        id: UUID = UUID(),
        name: String,
        minLatitude: Double,
        minLongitude: Double,
        maxLatitude: Double,
        maxLongitude: Double,
        minZoom: Int = Self.defaultMinZoom,
        maxZoom: Int = Self.defaultMaxZoom,
        tileCount: Int = 0,
        byteSize: Int = 0,
        status: OfflineMapPackStatus = .empty,
        errorMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minLatitude = min(minLatitude, maxLatitude)
        self.maxLatitude = max(minLatitude, maxLatitude)
        self.minLongitude = min(minLongitude, maxLongitude)
        self.maxLongitude = max(minLongitude, maxLongitude)
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.tileCount = tileCount
        self.byteSize = byteSize
        self.status = status
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }

    public var centerLatitude: Double { (minLatitude + maxLatitude) / 2 }
    public var centerLongitude: Double { (minLongitude + maxLongitude) / 2 }

    public var boundsLine: String {
        "\(LiveData.number(minLatitude, decimals: 3))…\(LiveData.number(maxLatitude, decimals: 3)) lat, "
            + "\(LiveData.number(minLongitude, decimals: 3))…\(LiveData.number(maxLongitude, decimals: 3)) lon"
    }

    public var sizeLine: String {
        if byteSize <= 0 { return "\(tileCount) tiles" }
        let mb = Double(byteSize) / 1_048_576
        return "\(tileCount) tiles · \(LiveData.number(mb, decimals: mb < 10 ? 1 : 0)) MB"
    }
}

/// Last successful weather render kept for airplane-mode answers.
public struct CachedWeather: Sendable, Equatable, Codable {
    public var placeTitle: String
    public var latitude: Double
    public var longitude: Double
    public var renderedText: String
    public var fetchedAt: Date

    public init(
        placeTitle: String,
        latitude: Double,
        longitude: Double,
        renderedText: String,
        fetchedAt: Date = Date()
    ) {
        self.placeTitle = placeTitle
        self.latitude = latitude
        self.longitude = longitude
        self.renderedText = renderedText
        self.fetchedAt = fetchedAt
    }
}
