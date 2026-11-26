import Foundation
import LLMKit

/// On-disk USDZ scans + JSON index under Application Support.
final class RoomScanFileStore: @unchecked Sendable {
    private let directory: URL
    private let indexURL: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func list() -> [RoomScanRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadIndexLocked().sorted { $0.createdAt > $1.createdAt }
    }

    func usdzURL(for record: RoomScanRecord) -> URL {
        directory.appendingPathComponent(record.usdzFileName)
    }

    func save(name: String, facts: RoomScanFacts, usdzData: Data) throws -> RoomScanRecord {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        let fileName = "room-\(id.uuidString.lowercased()).usdz"
        let url = directory.appendingPathComponent(fileName)
        try usdzData.write(to: url, options: .atomic)
        let record = RoomScanRecord(
            id: id,
            name: name.isEmpty ? "Room scan" : name,
            facts: facts,
            usdzFileName: fileName,
            byteSize: usdzData.count
        )
        var index = loadIndexLocked()
        index.append(record)
        try writeIndexLocked(index)
        return record
    }

    /// Copy an already-written temp USDZ into the store.
    func importUSDZ(from tempURL: URL, name: String, facts: RoomScanFacts) throws -> RoomScanRecord {
        let data = try Data(contentsOf: tempURL)
        return try save(name: name, facts: facts, usdzData: data)
    }

    func delete(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var index = loadIndexLocked()
        guard let record = index.first(where: { $0.id == id }) else { return }
        let url = directory.appendingPathComponent(record.usdzFileName)
        try? FileManager.default.removeItem(at: url)
        index.removeAll { $0.id == id }
        try writeIndexLocked(index)
    }

    func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var index = loadIndexLocked()
        guard let i = index.firstIndex(where: { $0.id == id }) else { return }
        index[i].name = trimmed
        try writeIndexLocked(index)
    }

    private func loadIndexLocked() -> [RoomScanRecord] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([RoomScanRecord].self, from: data)
        else { return [] }
        return decoded
    }

    private func writeIndexLocked(_ records: [RoomScanRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: indexURL, options: .atomic)
    }
}
