import XCTest
@testable import RAGKit

final class IndexTests: XCTestCase {
    func testStableHashIsDeterministic() {
        XCTAssertEqual(StableHash.fnv1a64("hello"), StableHash.fnv1a64("hello"))
        XCTAssertNotEqual(StableHash.fnv1a64("hello"), StableHash.fnv1a64("hellp"))
        XCTAssertEqual(StableHash.fingerprint("A  b\nC"), StableHash.fingerprint("a b c"))
        XCTAssertEqual(StableHash.fingerprint("x").count, 32)
    }

    func testTokenizerStemsAndDropsStopwords() {
        XCTAssertEqual(Tokenizer.terms("The batteries of the cells"), ["battery", "cell"])
        XCTAssertEqual(Tokenizer.words("Hello, World-2026!"), ["hello", "world", "2026"])
    }

    func testBM25PrefersRareTermsAndRespectsScope() {
        var index = BM25Index()
        let docA = UUID(), docB = UUID()
        let a1 = UUID(), b1 = UUID(), b2 = UUID()
        index.add(chunkID: a1, documentID: docA, text: "router firmware update schedule")
        index.add(chunkID: b1, documentID: docB, text: "router router router router")
        index.add(chunkID: b2, documentID: docB, text: "firmware")

        let results = index.search(query: "firmware update", limit: 3)
        XCTAssertEqual(results.first?.id, a1)

        let scoped = index.search(query: "router", limit: 5, allowedDocuments: [docB])
        XCTAssertEqual(scoped.map(\.id), [b1])

        index.remove(documentID: docA)
        XCTAssertFalse(index.search(query: "update", limit: 5).contains { $0.id == a1 })
    }

    func testVectorIndexCosineOrdering() {
        var index = VectorIndex(dimension: 3)
        let doc = UUID()
        let near = UUID(), far = UUID()
        index.add(id: near, documentID: doc, vector: VectorMath.normalized([1, 0.1, 0]))
        index.add(id: far, documentID: doc, vector: VectorMath.normalized([0, 1, 0]))
        let results = index.search(query: VectorMath.normalized([1, 0, 0]), limit: 2)
        XCTAssertEqual(results.map(\.id), [near, far])
        XCTAssertGreaterThan(results[0].cosine, results[1].cosine)
        XCTAssertEqual(index.vector(for: near)?.count, 3)
    }

    func testVectorBlobRoundTrip() {
        let vector: [Float] = [0.25, -1, 3.5, 0]
        XCTAssertEqual(VectorMath.vector(from: VectorMath.data(from: vector)), vector)
    }

    func testHashingEmbedderIsNormalisedAndDeterministic() async throws {
        let embedder = HashingEmbedder(dimension: 128)
        let vectors = try await embedder.embed(["router firmware", "router firmware", "sourdough starter"])
        XCTAssertEqual(VectorMath.norm(vectors[0]), 1.0, accuracy: 0.001)
        XCTAssertEqual(vectors[0], vectors[1])
        XCTAssertGreaterThan(VectorMath.dot(vectors[0], vectors[1]), VectorMath.dot(vectors[0], vectors[2]))
    }

    func testMMRDiversifiesNearDuplicates() async throws {
        let embedder = HashingEmbedder()
        var index = HybridIndex(dimension: embedder.dimension)
        let doc = UUID()
        let texts = [
            "alpha beta gamma delta epsilon",
            "alpha beta gamma delta epsilon",   // exact duplicate
            "alpha beta gamma delta zeta",
            "alpha unrelated filler words here",
        ]
        for (ordinal, text) in texts.enumerated() {
            let chunk = Chunk(documentID: doc, ordinal: ordinal, text: text)
            index.add(StoredChunk(chunk: chunk, vector: try await embedder.embed(text)))
        }
        let query = "alpha beta gamma delta"
        let queryVector = try await embedder.embed(query)

        let plain = index.search(query: query, queryVector: queryVector, limit: 2, allowedDocuments: nil,
                                 config: RetrievalConfig(mmrLambda: nil))
        let diverse = index.search(query: query, queryVector: queryVector, limit: 2, allowedDocuments: nil,
                                   config: RetrievalConfig(mmrLambda: 0.4))
        XCTAssertEqual(plain.count, 2)
        XCTAssertEqual(diverse.count, 2)
        XCTAssertNotEqual(plain.map(\.id), diverse.map(\.id), "MMR should swap in a less redundant chunk")
    }
}
