import XCTest
@testable import RAGKit
@testable import LLMKit

final class DocumentPackTests: XCTestCase {
    func testComposeAndParse() {
        let title = DocumentPack.compose(pack: "Voice notes", title: "Design sync")
        XCTAssertEqual(title, "Voice notes / Design sync")
        let parsed = DocumentPack.parse(title)
        XCTAssertEqual(parsed.pack, "Voice notes")
        XCTAssertEqual(parsed.title, "Design sync")
    }

    func testFilterAndListPacks() {
        let records = [
            DocumentRecord(title: "Voice notes / A", sourceName: "a", contentHash: "1", chunkCount: 1, pack: "Voice notes"),
            DocumentRecord(title: "Spec", sourceName: "b", contentHash: "2", chunkCount: 1, pack: "Work"),
            DocumentRecord(title: "Plain", sourceName: "c", contentHash: "3", chunkCount: 1),
        ]
        XCTAssertEqual(DocumentPack.filter(records, pack: "Voice notes").count, 1)
        XCTAssertEqual(DocumentPack.filter(records, pack: "").count, 1)
        XCTAssertEqual(DocumentPack.packs(in: records), ["Voice notes", "Work"])
        XCTAssertEqual(records[0].displayTitle, "A")
    }

    func testProfileFilter() {
        let a = UUID()
        let b = UUID()
        let records = [
            DocumentRecord(title: "One", sourceName: "a", contentHash: "1", chunkCount: 1, profileID: a),
            DocumentRecord(title: "Two", sourceName: "b", contentHash: "2", chunkCount: 1, profileID: b),
            DocumentRecord(title: "Legacy", sourceName: "c", contentHash: "3", chunkCount: 1),
        ]
        XCTAssertEqual(DocumentPack.forProfile(records, profileID: a).count, 2)
    }

    func testSetPackViaKnowledgeBase() async throws {
        let store = InMemoryChunkStore()
        let kb = KnowledgeBase(store: store, embedder: HashingEmbedder(dimension: 8))
        let outcome = try await kb.ingest(title: "Notes", text: "Hello world from a short note.")
        guard case .added(let record) = outcome else {
            return XCTFail("expected added")
        }
        let updated = try await kb.setPack(documentID: record.id, pack: "Work")
        XCTAssertEqual(updated?.pack, "Work")
        XCTAssertTrue(updated?.title.hasPrefix("Work /") == true)
        let text = await kb.exportText(documentID: record.id)
        XCTAssertTrue(text?.contains("Hello") == true)
    }

    func testRetrievalConfigFromWeights() {
        let weights = RetrievalWeights(vectorWeight: 1.4, keywordWeight: 0.7)
        let config = RetrievalConfig(weights: weights)
        XCTAssertEqual(config.vectorWeight, 1.4, accuracy: 0.001)
        XCTAssertEqual(config.keywordWeight, 0.7, accuracy: 0.001)
    }
}
