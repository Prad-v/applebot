import Foundation

/// Budgets the ~4K token context window across instructions, history, retrieved
/// context, the question, and room for the answer.
public struct ContextManager: Sendable {
    public var windowTokens: Int
    public var answerReserve: Int
    /// Fraction of the usable window (window - answer reserve) history may occupy before compaction.
    public var historyShare: Double
    public var maxSnippetTokens: Int

    public init(
        windowTokens: Int = 4096,
        answerReserve: Int = 1000,
        historyShare: Double = 0.4,
        maxSnippetTokens: Int = 320
    ) {
        self.windowTokens = windowTokens
        self.answerReserve = answerReserve
        self.historyShare = historyShare
        self.maxSnippetTokens = maxSnippetTokens
    }

    /// Result of fitting a conversation into the window.
    public struct Fit: Sendable, Equatable {
        public var history: [Turn]
        public var dropped: [Turn]
        public var snippets: [ContextSnippet]
        public var estimatedTokens: Int
    }

    public var usableTokens: Int { max(0, windowTokens - answerReserve) }

    /// Fit history and snippets under budget.
    ///
    /// Order of sacrifice: oldest history turns first (returned in `dropped` so the caller can
    /// fold them into the rolling summary), then lowest-ranked snippets, then snippet length.
    /// `pressure` (>= 1) shrinks the budget further, used when retrying after an overflow.
    public func fit(
        instructions: String,
        history: [Turn],
        snippets: [ContextSnippet],
        question: String,
        pressure: Double = 1.0
    ) -> Fit {
        let scale = 1.0 / max(1.0, pressure)
        let usable = Int(Double(usableTokens) * scale)
        let fixed = TokenEstimator.estimate(instructions) + TokenEstimator.estimate(question) + 40

        // 1. History: keep newest turns within its share of the budget.
        let historyBudget = max(0, Int(Double(usable) * historyShare))
        var keptHistory = history
        var dropped: [Turn] = []
        while !keptHistory.isEmpty, TokenEstimator.estimate(keptHistory) > historyBudget {
            dropped.append(keptHistory.removeFirst())
        }
        // Never begin the kept history with an assistant reply that lost its question.
        if keptHistory.first?.role == .assistant {
            dropped.append(keptHistory.removeFirst())
        }

        // 2. Snippets: whatever remains after fixed parts and kept history.
        var snippetBudget = usable - fixed - TokenEstimator.estimate(keptHistory)
        var keptSnippets: [ContextSnippet] = []
        for snippet in snippets {
            guard snippetBudget > 24 else { break }
            let perSnippetCap = min(maxSnippetTokens, snippetBudget)
            var trimmed = snippet
            trimmed.text = TokenEstimator.truncate(snippet.text, toTokens: perSnippetCap)
            let cost = TokenEstimator.estimate(trimmed.text) + 12
            guard cost <= snippetBudget else { break }
            keptSnippets.append(trimmed)
            snippetBudget -= cost
        }

        let total = fixed
            + TokenEstimator.estimate(keptHistory)
            + keptSnippets.reduce(0) { $0 + TokenEstimator.estimate($1.text) + 12 }
        return Fit(history: keptHistory, dropped: dropped, snippets: keptSnippets, estimatedTokens: total)
    }

    /// True when history alone is using more than `fraction` of its share, so the caller
    /// can compact proactively instead of waiting for an overflow error.
    public func shouldCompact(history: [Turn], fraction: Double = 1.0) -> Bool {
        let budget = Double(usableTokens) * historyShare * fraction
        return Double(TokenEstimator.estimate(history)) > budget
    }
}
