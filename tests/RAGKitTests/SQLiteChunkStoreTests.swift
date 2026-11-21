#if canImport(SQLite3)
import XCTest
@testable import RAGKit

/// Runs on Apple platforms only (system SQLite3). Executed by the macOS CI job.
final class SQLiteChunkStoreTests: XCTestCase {
    private func sample() -> (DocumentRecord, [StoredChunk]) {
        let record = DocumentRecord(title: "Doc", sourceName: "doc.md", contentHash: "abc123", chunkCount: 2)
        let chunks = [
            StoredChunk(chunk: Chunk(documentID: record.id, ordinal: 0, text: "first", page: 1, heading: "Intro"),
                        vector: [0.5, 0.5, 0, 0]),
            StoredChunk(chunk: Chunk(documentID: record.id, ordinal: 1, text: "second"),
                        vector: [0, 0, 1, 0]),
        ]
        return (record, chunks)
    }

    func testRoundTrip() async throws {
        let store = try SQLiteChunkStore(url: nil)
        let (record, chunks) = sample()
        try await store.insert(document: record, chunks: chunks)

        let documents = try await store.documents()
        XCTAssertEqual(documents.map(\.title), ["Doc"])
        let found = try await store.document(withHash: "abc123")
        XCTAssertEqual(found?.id, record.id)

        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].chunk.heading, "Intro")
        XCTAssertEqual(loaded[0].chunk.page, 1)
        XCTAssertNil(loaded[1].chunk.page)
        XCTAssertNil(loaded[1].chunk.heading)
        XCTAssertEqual(loaded[0].vector, [0.5, 0.5, 0, 0])
    }

    func testDeleteCascadesAndHashIsUnique() async throws {
        let store = try SQLiteChunkStore(url: nil)
        let (record, chunks) = sample()
        try await store.insert(document: record, chunks: chunks)

        let duplicate = DocumentRecord(title: "Dup", sourceName: "d", contentHash: "abc123", chunkCount: 0)
        do {
            try await store.insert(document: duplicate, chunks: [])
            XCTFail("expected unique constraint failure")
        } catch {
            XCTAssertTrue(error is RAGError)
        }

        try await store.delete(documentID: record.id)
        let remaining = try await store.loadAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testEmbedderIdentifierAndVectorReplacement() async throws {
        let store = try SQLiteChunkStore(url: nil)
        let initial = try await store.embedderIdentifier()
        XCTAssertNil(initial)
        try await store.setEmbedderIdentifier("a")
        try await store.setEmbedderIdentifier("b")
        let identifier = try await store.embedderIdentifier()
        XCTAssertEqual(identifier, "b")

        let (record, chunks) = sample()
        try await store.insert(document: record, chunks: chunks)
        try await store.replaceVectors([chunks[0].chunk.id: [9, 9]])
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded[0].vector, [9, 9])
    }

    func testPersistsToDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("applebot-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let (record, chunks) = sample()
        do {
            let store = try SQLiteChunkStore(url: url)
            try await store.insert(document: record, chunks: chunks)
        }
        let reopened = try SQLiteChunkStore(url: url)
        let loaded = try await reopened.loadAll()
        XCTAssertEqual(loaded.count, 2)
    }

    func testKnowledgeBaseWorksOnSQLite() async throws {
        let kb = KnowledgeBase(store: try SQLiteChunkStore(url: nil), embedder: HashingEmbedder())
        try await kb.ingest(title: "Manual", text: "# Reset\nHold the reset button for ten seconds.")
        let hits = try await kb.search(query: "reset button")
        XCTAssertEqual(hits.first?.documentTitle, "Manual")
    }
}
#endif
