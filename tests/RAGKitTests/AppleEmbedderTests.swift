#if canImport(NaturalLanguage)
import XCTest
@testable import RAGKit

/// Apple-only: exercises the built-in NaturalLanguage embeddings. Runs in the macOS CI job.
final class AppleEmbedderTests: XCTestCase {
    func testSentenceEmbedderIsNormalisedAndSemantic() async throws {
        guard let embedder = NLSentenceEmbedder() else {
            throw XCTSkip("NLEmbedding sentence model unavailable on this machine")
        }
        let vectors = try await embedder.embed([
            "How do I reset my wifi router?",
            "Hold the button to restore the router to factory settings.",
            "Bake the bread at high temperature for forty minutes.",
        ])
        XCTAssertEqual(vectors[0].count, embedder.dimension)
        XCTAssertEqual(VectorMath.norm(vectors[0]), 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(
            VectorMath.dot(vectors[0], vectors[1]), VectorMath.dot(vectors[0], vectors[2]),
            "related sentences should be closer than unrelated ones"
        )
    }

    func testPreferredEmbedderAlwaysReturnsSomething() async throws {
        let embedder = EmbedderFactory.preferred()
        let vector = try await embedder.embed("hello world")
        XCTAssertEqual(vector.count, embedder.dimension)
        XCTAssertFalse(embedder.identifier.isEmpty)
    }

    func testKnowledgeBaseWithAppleEmbedderFindsParaphrase() async throws {
        guard let embedder = NLSentenceEmbedder() else { throw XCTSkip("NLEmbedding unavailable") }
        let kb = KnowledgeBase(store: InMemoryChunkStore(), embedder: embedder)
        try await kb.ingest(title: "Router", text: "# Reset\nHold the small button underneath for ten seconds to restore factory settings.")
        try await kb.ingest(title: "Bread", text: "# Baking\nPreheat the oven and bake the loaf until the crust is golden brown.")
        let hits = try await kb.search(query: "how can I wipe my device back to defaults", limit: 2)
        XCTAssertEqual(hits.first?.documentTitle, "Router")
    }
}
#endif
