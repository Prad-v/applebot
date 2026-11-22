import Foundation

/// A compact “write like me” card: a few samples plus optional traits.
/// Used as a clear upgrade SKU for on-device rewrite — no cloud fine-tune.
public struct StyleCard: Sendable, Codable, Equatable {
    public var samples: [String]
    public var traits: String
    public var isEnabled: Bool

    public static let maxSamples = 3
    public static let promptTokens = 160

    public init(samples: [String] = [], traits: String = "", isEnabled: Bool = false) {
        self.samples = samples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(Self.maxSamples)
            .map { String($0.prefix(400)) }
        self.traits = traits.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
    }

    public var isReady: Bool {
        isEnabled && (!samples.isEmpty || !traits.isEmpty)
    }

    /// Instruction snippet describing the user's voice.
    public func promptBlock(maxTokens: Int = promptTokens) -> String? {
        guard isReady else { return nil }
        var parts: [String] = ["Rewrite in the user's personal writing voice."]
        if !traits.isEmpty {
            parts.append("Traits: \(TokenEstimator.truncate(traits, toTokens: 40))")
        }
        if !samples.isEmpty {
            parts.append("Examples of their writing:")
            for (index, sample) in samples.enumerated() {
                parts.append("(\(index + 1)) \(TokenEstimator.truncate(sample, toTokens: 50))")
            }
        }
        parts.append("Keep the meaning. Do not add a preamble. Output only the rewritten text.")
        let joined = parts.joined(separator: "\n")
        return TokenEstimator.truncate(joined, toTokens: maxTokens)
    }

    /// Strip common rewrite prefixes so the draft body is clean.
    public static func extractDraft(from question: String) -> String {
        var text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "rewrite this:", "rewrite:", "rewrite ", "rephrase this:", "rephrase:",
            "reword this:", "reword:", "polish this:", "polish:", "in my voice:",
            "make this sound like me:", "edit this:", "edit:",
        ]
        let lowered = text.lowercased()
        for prefix in prefixes {
            if lowered.hasPrefix(prefix) {
                let start = text.index(text.startIndex, offsetBy: prefix.count)
                text = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return text
    }

    public func rewriteRequest(draft: String) -> LLMRequest {
        let body = Self.extractDraft(from: draft)
        let instructions = promptBlock() ?? "Rewrite clearly and naturally. Output only the rewritten text."
        return LLMRequest(
            instructions: instructions,
            prompt: "Draft to rewrite:\n\(TokenEstimator.truncate(body, toTokens: 600))"
        )
    }
}
