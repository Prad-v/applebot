import Foundation

/// A labelled retrieval question.
public struct EvalCase: Sendable, Codable, Equatable {
    public var question: String
    /// Title of the document that should be retrieved.
    public var document: String
    /// Optional phrase that the winning chunk must contain (case-insensitive).
    public var phrase: String?

    public init(question: String, document: String, phrase: String? = nil) {
        self.question = question
        self.document = document
        self.phrase = phrase
    }
}

public struct EvalReport: Sendable, Equatable {
    public struct CaseResult: Sendable, Equatable {
        public var question: String
        /// 1-based rank of the first correct hit, nil when missed.
        public var rank: Int?
    }

    public var k: Int
    public var results: [CaseResult]

    public var recallAtK: Double {
        guard !results.isEmpty else { return 0 }
        return Double(results.filter { $0.rank != nil }.count) / Double(results.count)
    }

    /// Mean reciprocal rank.
    public var mrr: Double {
        guard !results.isEmpty else { return 0 }
        return results.reduce(0.0) { $0 + ($1.rank.map { 1.0 / Double($0) } ?? 0) } / Double(results.count)
    }

    public var misses: [String] { results.filter { $0.rank == nil }.map(\.question) }
}

/// Measures retrieval quality (recall@k and MRR) without involving an LLM.
public enum RetrievalEvaluator {
    public static func evaluate(
        knowledgeBase: KnowledgeBase, cases: [EvalCase], k: Int = 4,
        config: RetrievalConfig = RetrievalConfig()
    ) async throws -> EvalReport {
        var results: [EvalReport.CaseResult] = []
        for testCase in cases {
            let hits = try await knowledgeBase.search(query: testCase.question, limit: k, config: config)
            let rank = hits.firstIndex { hit in
                guard hit.documentTitle == testCase.document else { return false }
                guard let phrase = testCase.phrase else { return true }
                return hit.chunk.text.localizedCaseInsensitiveContains(phrase)
            }.map { $0 + 1 }
            results.append(.init(question: testCase.question, rank: rank))
        }
        return EvalReport(k: k, results: results)
    }
}
