import XCTest
@testable import RAGKit

final class KnowledgeBaseTests: XCTestCase {
    private func makeKnowledgeBase(
        store: ChunkStore = InMemoryChunkStore(), embedder: Embedder = HashingEmbedder()
    ) -> KnowledgeBase {
        KnowledgeBase(store: store, embedder: embedder)
    }

    func testIngestAndSearchFindsRelevantDocument() async throws {
        let kb = makeKnowledgeBase()
        try await kb.ingest(title: "Cooking", text: "# Pasta\nBoil the spaghetti in salted water for nine minutes.")
        try await kb.ingest(title: "Garden", text: "# Roses\nPrune the rose bushes in early spring after the frost.")

        let hits = try await kb.search(query: "how long to boil spaghetti", limit: 2)
        XCTAssertEqual(hits.first?.documentTitle, "Cooking")
        XCTAssertNotNil(hits.first?.keywordRank)
        XCTAssertEqual(hits.first?.snippet.title, "Cooking")
        XCTAssertEqual(hits.first?.snippet.location, "Pasta")
    }

    func testDuplicateImportIsDetected() async throws {
        let kb = makeKnowledgeBase()
        let first = try await kb.ingest(title: "A", text: "Same content   here.")
        let second = try await kb.ingest(title: "B", text: "same content here.")
        guard case .added = first, case .duplicate(let existing) = second else {
            return XCTFail("expected added then duplicate, got \(first) / \(second)")
        }
        XCTAssertEqual(existing.title, "A")
        let documents = await kb.documents()
        XCTAssertEqual(documents.count, 1)
    }

    func testEmptyDocumentIsRejected() async {
        let kb = makeKnowledgeBase()
        do {
            try await kb.ingest(title: "Empty", text: "   \n  ")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? RAGError, .emptyDocument)
        }
    }

    func testRemoveDocumentRemovesItsChunksFromSearch() async throws {
        let kb = makeKnowledgeBase()
        guard case .added(let record) = try await kb.ingest(title: "Gone", text: "unique zebra stripes pattern") else {
            return XCTFail("not added")
        }
        try await kb.ingest(title: "Stay", text: "something about giraffes and tall trees")
        var hits = try await kb.search(query: "zebra stripes")
        XCTAssertTrue(hits.contains { $0.documentTitle == "Gone" })

        try await kb.remove(documentID: record.id)
        hits = try await kb.search(query: "zebra stripes")
        XCTAssertFalse(hits.contains { $0.documentTitle == "Gone" })
        let count = await kb.documents().count
        XCTAssertEqual(count, 1)
    }

    func testScopeRestrictsResults() async throws {
        let kb = makeKnowledgeBase()
        guard case .added(let a) = try await kb.ingest(title: "A", text: "battery charging instructions for the camera"),
              case .added = try await kb.ingest(title: "B", text: "battery recycling rules for the city")
        else { return XCTFail("not added") }

        let scoped = try await kb.search(query: "battery", limit: 5, scope: [a.id])
        XCTAssertEqual(Set(scoped.map(\.documentTitle)), ["A"])
        let none = try await kb.search(query: "battery", scope: [])
        XCTAssertTrue(none.isEmpty)
    }

    func testPersistenceAcrossReopen() async throws {
        let store = InMemoryChunkStore()
        let first = makeKnowledgeBase(store: store)
        try await first.ingest(title: "Persisted", text: "The quokka is a small marsupial from Western Australia.")

        let second = makeKnowledgeBase(store: store)
        try await second.open()
        let hits = try await second.search(query: "quokka marsupial")
        XCTAssertEqual(hits.first?.documentTitle, "Persisted")
        let documents = await second.documents()
        XCTAssertEqual(documents.count, 1)
    }

    func testEmbedderChangeTriggersReindex() async throws {
        let store = InMemoryChunkStore()
        let small = makeKnowledgeBase(store: store, embedder: HashingEmbedder(dimension: 64))
        try await small.ingest(title: "Doc", text: "The quokka is a small marsupial from Western Australia.")

        let large = makeKnowledgeBase(store: store, embedder: HashingEmbedder(dimension: 256))
        try await large.open()
        let stored = try await store.loadAll()
        XCTAssertTrue(stored.allSatisfy { $0.vector.count == 256 })
        let identifier = try await store.embedderIdentifier()
        XCTAssertEqual(identifier, "hashing-256-v1")
        let hits = try await large.search(query: "quokka")
        XCTAssertEqual(hits.first?.documentTitle, "Doc")
    }

    func testRetrieverClosureReturnsSnippets() async throws {
        let kb = makeKnowledgeBase()
        try await kb.ingest(title: "Manual", text: "# Reset\nHold the reset button for ten seconds.")
        let snippets = try await kb.retriever(limit: 2)("reset button")
        XCTAssertEqual(snippets.first?.title, "Manual")
        XCTAssertTrue(snippets.first?.text.contains("ten seconds") == true)
    }

    func testSearchOnEmptyKnowledgeBaseReturnsNothing() async throws {
        let hits = try await makeKnowledgeBase().search(query: "anything")
        XCTAssertTrue(hits.isEmpty)
    }

    func testRemoveAllClearsEverything() async throws {
        let kb = makeKnowledgeBase()
        try await kb.ingest(title: "X", text: "some text to remember")
        try await kb.removeAll()
        let documents = await kb.documents()
        XCTAssertTrue(documents.isEmpty)
        let hits = try await kb.search(query: "remember")
        XCTAssertTrue(hits.isEmpty)
    }

    func testProgressReachesOne() async throws {
        let kb = KnowledgeBase(store: InMemoryChunkStore(), embedder: HashingEmbedder(), batchSize: 2)
        let text = (0..<40).map { "Paragraph \($0) says something different about topic \($0)." }.joined(separator: "\n\n")
        let progress = ProgressRecorder()
        try await kb.ingest(title: "Long", blocks: [TextBlock(text: text)]) { value in
            Task { await progress.record(value) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let values = await progress.values
        XCTAssertEqual(values.last ?? 0, 1.0, accuracy: 0.0001)
    }
}

private actor ProgressRecorder {
    private(set) var values: [Double] = []
    func record(_ value: Double) { values.append(value) }
}
