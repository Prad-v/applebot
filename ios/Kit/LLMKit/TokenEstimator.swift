import Foundation

/// Cheap, conservative token estimation.
///
/// Foundation Models does not expose a public tokenizer, so we approximate with
/// ~3.5 characters per token (slightly conservative versus the ~4 typical for English),
/// which keeps us on the safe side of the ~4K context window.
public enum TokenEstimator {
    public static let charactersPerToken: Double = 3.5

    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / charactersPerToken).rounded(.up))
    }

    public static func estimate(_ turns: [Turn]) -> Int {
        turns.reduce(0) { $0 + estimate($1.text) + 4 } // small per-message overhead
    }

    /// Truncate `text` to roughly `maxTokens`, cutting on a word boundary when possible.
    public static func truncate(_ text: String, toTokens maxTokens: Int) -> String {
        guard maxTokens > 0 else { return "" }
        let maxChars = Int(Double(maxTokens) * charactersPerToken)
        guard text.count > maxChars else { return text }
        let cut = text.prefix(maxChars)
        if let lastSpace = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: lastSpace) > maxChars / 2 {
            return String(cut[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }
}
