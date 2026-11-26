import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pre-download size estimate (Google Maps–style “about X MB”).
public struct OfflineMapEstimate: Sendable, Equatable {
    public var tileCount: Int
    public var estimatedBytes: Int
    public var isValid: Bool
    public var message: String?

    /// Typical OpenTopoMap PNG size used for estimates before the real download.
    public static let averageBytesPerTile = 22_000

    public init(tileCount: Int, estimatedBytes: Int, isValid: Bool, message: String? = nil) {
        self.tileCount = tileCount
        self.estimatedBytes = estimatedBytes
        self.isValid = isValid
        self.message = message
    }

    public var sizeLine: String {
        let mb = Double(estimatedBytes) / 1_048_576
        if mb < 0.1 {
            return "\(tileCount) tiles · <0.1 MB"
        }
        return "\(tileCount) tiles · about \(LiveData.number(mb, decimals: mb < 10 ? 1 : 0)) MB"
    }
}

/// Named detail presets for the offline-area picker (maps to max zoom).
public enum OfflineMapDetail: String, Sendable, CaseIterable, Identifiable {
    case overview
    case standard
    case detailed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overview: return "Overview"
        case .standard: return "Standard"
        case .detailed: return "More detail"
        }
    }

    public var minZoom: Int {
        switch self {
        case .overview: return 7
        case .standard: return 8
        case .detailed: return 9
        }
    }

    public var maxZoom: Int {
        switch self {
        case .overview: return 11
        case .standard: return 13
        case .detailed: return 14
        }
    }
}

/// Downloads OpenTopoMap raster tiles for a bounding box into an `OfflineMapStore`.
///
/// Network is used only while downloading. Once a pack is `ready`, MapKit overlays read tiles
/// from disk with no network. Respect OpenTopoMap / OSM attribution (CC-BY-SA).
public struct OfflineMapDownloader: Sendable {
    public static let defaultTileURLTemplate = "https://tile.opentopomap.org/{z}/{x}/{y}.png"
    public static let attribution = "© OpenStreetMap contributors, SRTM | © OpenTopoMap (CC-BY-SA)"
    public static let service = "OpenTopoMap"

    private let http: HTTPClient
    private let store: any OfflineMapStore
    private let template: String

    public init(
        store: any OfflineMapStore,
        http: HTTPClient = URLSessionHTTPClient(),
        tileURLTemplate: String = Self.defaultTileURLTemplate
    ) {
        self.store = store
        self.http = http
        self.template = tileURLTemplate
    }

    /// Soft estimate for the picker UI (does not throw).
    public static func estimate(
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
        minZoom: Int, maxZoom: Int,
        bytesPerTile: Int = OfflineMapEstimate.averageBytesPerTile
    ) -> OfflineMapEstimate {
        do {
            let count = try validate(
                minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
                minZoom: minZoom, maxZoom: maxZoom
            )
            return OfflineMapEstimate(
                tileCount: count,
                estimatedBytes: count * bytesPerTile,
                isValid: true
            )
        } catch let error as ConnectorError {
            let count = GeoMath.tileCount(
                minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
                minZoom: minZoom, maxZoom: maxZoom
            )
            return OfflineMapEstimate(
                tileCount: max(count, 0),
                estimatedBytes: max(count, 0) * bytesPerTile,
                isValid: false,
                message: error.errorDescription
            )
        } catch {
            return OfflineMapEstimate(
                tileCount: 0, estimatedBytes: 0, isValid: false,
                message: error.localizedDescription
            )
        }
    }

    /// Estimate tile count before downloading. Throws if the region is too large.
    public static func validate(
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
        minZoom: Int, maxZoom: Int
    ) throws -> Int {
        guard (-90...90).contains(minLat), (-90...90).contains(maxLat),
              (-180...180).contains(minLon), (-180...180).contains(maxLon) else {
            throw ConnectorError.invalidArgument("Map bounds must be valid latitudes and longitudes.")
        }
        guard minZoom >= 0, maxZoom <= 15, minZoom <= maxZoom else {
            throw ConnectorError.invalidArgument("Zoom must be between 0 and 15, with min ≤ max.")
        }
        let count = GeoMath.tileCount(
            minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
            minZoom: minZoom, maxZoom: maxZoom
        )
        guard count > 0 else {
            throw ConnectorError.invalidArgument("That region covers no map tiles.")
        }
        guard count <= OfflineMapPackInfo.maxTilesPerPack else {
            throw ConnectorError.invalidArgument(
                "That region needs \(count) tiles (max \(OfflineMapPackInfo.maxTilesPerPack)). "
                    + "Pinch to shrink the area or choose Overview / Standard detail."
            )
        }
        return count
    }

    /// Build a pack from an on-screen selection rectangle (lat/lon bounds).
    public static func pack(
        name: String,
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
        detail: OfflineMapDetail = .standard
    ) -> OfflineMapPackInfo {
        OfflineMapPackInfo(
            name: name.isEmpty ? "Offline area" : name,
            minLatitude: minLat,
            minLongitude: minLon,
            maxLatitude: maxLat,
            maxLongitude: maxLon,
            minZoom: detail.minZoom,
            maxZoom: detail.maxZoom
        )
    }

    /// Create or refresh a pack. Progress is 0…1.
    public func download(
        pack: OfflineMapPackInfo,
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> OfflineMapPackInfo {
        let expected = try Self.validate(
            minLat: pack.minLatitude, minLon: pack.minLongitude,
            maxLat: pack.maxLatitude, maxLon: pack.maxLongitude,
            minZoom: pack.minZoom, maxZoom: pack.maxZoom
        )
        var working = pack
        working.status = .downloading
        working.errorMessage = nil
        working.updatedAt = Date()
        await store.savePack(working)

        var done = 0
        var bytes = 0
        do {
            for z in pack.minZoom...pack.maxZoom {
                let coords = GeoMath.tiles(
                    minLat: pack.minLatitude, minLon: pack.minLongitude,
                    maxLat: pack.maxLatitude, maxLon: pack.maxLongitude,
                    zoom: z
                )
                for tile in coords {
                    try Task.checkCancellation()
                    if await store.hasTile(packID: pack.id, z: z, x: tile.x, y: tile.y),
                       let existing = await store.loadTile(packID: pack.id, z: z, x: tile.x, y: tile.y) {
                        done += 1
                        bytes += existing.count
                    } else {
                        let url = try Self.tileURL(template: template, z: z, x: tile.x, y: tile.y)
                        let data = try await LiveData.fetch(http, url, service: Self.service)
                        guard !data.isEmpty else {
                            throw ConnectorError.unexpectedResponse("OpenTopoMap returned an empty tile.")
                        }
                        try await store.saveTile(packID: pack.id, z: z, x: tile.x, y: tile.y, data: data)
                        done += 1
                        bytes += data.count
                    }
                    if let progress {
                        await progress(Double(done) / Double(max(expected, 1)))
                    }
                }
            }
            working.status = .ready
            working.tileCount = done
            working.byteSize = bytes
            working.errorMessage = nil
            working.updatedAt = Date()
            await store.savePack(working)
            return working
        } catch is CancellationError {
            working.status = .failed
            working.errorMessage = "Download cancelled."
            working.updatedAt = Date()
            await store.savePack(working)
            throw CancellationError()
        } catch {
            working.status = .failed
            working.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            working.updatedAt = Date()
            await store.savePack(working)
            throw error
        }
    }

    public static func tileURL(template: String, z: Int, x: Int, y: Int) throws -> URL {
        let filled = template
            .replacingOccurrences(of: "{z}", with: String(z))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y))
        guard let url = URL(string: filled) else {
            throw ConnectorError.invalidArgument("Could not build a tile URL.")
        }
        return url
    }

    /// Pick a roughly square region centred on a fix (degrees). ~0.15° ≈ 10–15 km.
    public static func region(
        around fix: LocationFix,
        name: String,
        halfSpanDegrees: Double = 0.12,
        minZoom: Int = OfflineMapPackInfo.defaultMinZoom,
        maxZoom: Int = OfflineMapPackInfo.defaultMaxZoom
    ) -> OfflineMapPackInfo {
        OfflineMapPackInfo(
            name: name,
            minLatitude: fix.latitude - halfSpanDegrees,
            minLongitude: fix.longitude - halfSpanDegrees,
            maxLatitude: fix.latitude + halfSpanDegrees,
            maxLongitude: fix.longitude + halfSpanDegrees,
            minZoom: minZoom,
            maxZoom: maxZoom
        )
    }
}
