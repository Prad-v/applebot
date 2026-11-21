import XCTest
@testable import RAGKit

/// Retrieval-quality gate: measures recall@k and MRR over labelled questions without an LLM.
///
/// Fixtures live in `tests/fixtures`. Add a document and cases there whenever retrieval behaviour
/// changes, so regressions in chunking, ranking or fusion are caught in CI.
final class RetrievalEvalTests: XCTestCase {
    static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // RAGKitTests
        .deletingLastPathComponent()      // tests
        .appendingPathComponent("fixtures")

    private func loadKnowledgeBase() async throws -> KnowledgeBase {
        let kb = KnowledgeBase(store: InMemoryChunkStore(), embedder: HashingEmbedder())
        let docs = Self.fixturesURL.appendingPathComponent("docs")
        let files = try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let blocks = try await PlainTextExtractor().extract(from: file)
            try await kb.ingest(title: file.deletingPathExtension().lastPathComponent, blocks: blocks)
        }
        return kb
    }

    private func loadCases() throws -> [EvalCase] {
        let data = try Data(contentsOf: Self.fixturesURL.appendingPathComponent("eval.json"))
        return try JSONDecoder().decode([EvalCase].self, from: data)
    }

    func testRecallAtFourMeetsThreshold() async throws {
        let kb = try await loadKnowledgeBase()
        let cases = try loadCases()
        let report = try await RetrievalEvaluator.evaluate(knowledgeBase: kb, cases: cases, k: 4)
        print("retrieval eval: recall@4=\(report.recallAtK) mrr=\(report.mrr) misses=\(report.misses)")
        XCTAssertGreaterThanOrEqual(report.recallAtK, 0.9, "misses: \(report.misses)")
        XCTAssertGreaterThanOrEqual(report.mrr, 0.7)
    }

    func testRecallAtOneIsReasonable() async throws {
        let kb = try await loadKnowledgeBase()
        let report = try await RetrievalEvaluator.evaluate(knowledgeBase: kb, cases: try loadCases(), k: 1)
        XCTAssertGreaterThanOrEqual(report.recallAtK, 0.7, "misses: \(report.misses)")
    }

    func testHybridBeatsOrMatchesVectorOnly() async throws {
        let kb = try await loadKnowledgeBase()
        let cases = try loadCases()
        let hybrid = try await RetrievalEvaluator.evaluate(knowledgeBase: kb, cases: cases, k: 2)
        let vectorOnly = try await RetrievalEvaluator.evaluate(
            knowledgeBase: kb, cases: cases, k: 2, config: RetrievalConfig(keywordWeight: 0)
        )
        XCTAssertGreaterThanOrEqual(hybrid.recallAtK, vectorOnly.recallAtK)
    }

    func testDocumentExtractorHandlesMarkdownAndRejectsUnknown() async throws {
        let file = Self.fixturesURL.appendingPathComponent("docs/aurora-router.md")
        let blocks = try await DocumentExtractor().extract(from: file)
        XCTAssertTrue(blocks.first?.text.contains("Aurora X2") == true)

        do {
            _ = try await DocumentExtractor().extract(from: URL(fileURLWithPath: "/tmp/file.xyz123"))
            XCTFail("expected unsupported type")
        } catch {
            XCTAssertEqual(error as? RAGError, .unsupportedFileType("xyz123"))
        }
    }
}
