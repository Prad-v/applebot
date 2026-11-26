import Foundation
import ConnectorKit

/// Offline map packs on disk: `maps/index.json` + `maps/<packID>/<z>/<x>/<y>.png`.
actor OfflineMapFileStore: OfflineMapStore {
    private let root: URL
    private var packsByID: [UUID: OfflineMapPackInfo] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL) {
        self.root = directory
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let loaded: [OfflineMapPackInfo] = Self.load(
            from: root.appendingPathComponent("index.json"),
            decoder: decoder
        ) {
            for pack in loaded { packsByID[pack.id] = pack }
        }
    }

    func packs() -> [OfflineMapPackInfo] {
        packsByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func savePack(_ pack: OfflineMapPackInfo) {
        packsByID[pack.id] = pack
        persistIndex()
        let folder = packFolder(pack.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func deletePack(id: UUID) throws {
        packsByID.removeValue(forKey: id)
        persistIndex()
        let folder = packFolder(id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    func hasTile(packID: UUID, z: Int, x: Int, y: Int) -> Bool {
        FileManager.default.fileExists(atPath: tileURL(packID: packID, z: z, x: x, y: y).path)
    }

    func loadTile(packID: UUID, z: Int, x: Int, y: Int) -> Data? {
        try? Data(contentsOf: tileURL(packID: packID, z: z, x: x, y: y))
    }

    /// Absolute file URL for MapKit overlays.
    func tileFileURL(packID: UUID, z: Int, x: Int, y: Int) -> URL {
        tileURL(packID: packID, z: z, x: x, y: y)
    }

    func saveTile(packID: UUID, z: Int, x: Int, y: Int, data: Data) throws {
        let url = tileURL(packID: packID, z: z, x: x, y: y)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if var pack = packsByID[packID] {
            pack.tileCount = countTiles(packID: packID)
            pack.byteSize = folderSize(packID: packID)
            packsByID[packID] = pack
            persistIndex()
        }
    }

    private func packFolder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func tileURL(packID: UUID, z: Int, x: Int, y: Int) -> URL {
        packFolder(packID)
            .appendingPathComponent("\(z)", isDirectory: true)
            .appendingPathComponent("\(x)", isDirectory: true)
            .appendingPathComponent("\(y).png", isDirectory: false)
    }

    private func persistIndex() {
        let list = packs()
        Self.save(list, to: root.appendingPathComponent("index.json"), encoder: encoder)
    }

    private func countTiles(packID: UUID) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: packFolder(packID),
            includingPropertiesForKeys: nil
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator where url.pathExtension == "png" {
            count += 1
        }
        return count
    }

    private func folderSize(packID: UUID) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: packFolder(packID),
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += values?.fileSize ?? 0
        }
        return total
    }

    private static func load<T: Decodable>(from url: URL, decoder: JSONDecoder) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

actor FileWeatherCacheStore: WeatherCacheStore {
    private let url: URL
    private var cached: CachedWeather?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL) {
        self.url = directory.appendingPathComponent("weather-cache.json")
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(CachedWeather.self, from: data) {
            cached = decoded
        }
    }

    func load() -> CachedWeather? { cached }

    func save(_ cached: CachedWeather) {
        self.cached = cached
        if let data = try? encoder.encode(cached) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func clear() {
        cached = nil
        try? FileManager.default.removeItem(at: url)
    }
}
