import Foundation

/// A durable fact remembered across chats. Lives only on the device.
public struct MemoryFact: Sendable, Codable, Equatable, Identifiable, Hashable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case person
        case preference
        case event
        case openLoop
        case other
    }

    public var id: UUID
    public var text: String
    public var category: Category
    public var updatedAt: Date
    public var pinned: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        category: Category = .other,
        updatedAt: Date = Date(),
        pinned: Bool = false
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.category = category
        self.updatedAt = updatedAt
        self.pinned = pinned
    }
}

/// Merges, ranks and renders memory facts for the prompt.
public enum MemoryBudget {
    /// Soft cap on how many facts are kept in the store.
    public static let maxStored = 60
    /// Soft token budget for the "Things you remember" block.
    public static let promptTokens = 200
    /// Max facts injected into one prompt.
    public static let promptFacts = 12

    /// Prefer pinned, then newest. Drops near-duplicates (case-insensitive containment).
    public static func merge(existing: [MemoryFact], adding candidates: [MemoryFact]) -> [MemoryFact] {
        var result = existing
        for candidate in candidates {
            let cleaned = candidate.text
            guard cleaned.count >= 8, cleaned.count <= 180 else { continue }
            if let index = result.firstIndex(where: { similar($0.text, cleaned) }) {
                var updated = result[index]
                // Prefer the longer / newer wording.
                if cleaned.count >= updated.text.count {
                    updated.text = cleaned
                    updated.category = candidate.category
                }
                updated.updatedAt = candidate.updatedAt
                result[index] = updated
            } else {
                result.append(candidate)
            }
        }
        result.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
        if result.count > maxStored {
            let pinned = result.filter(\.pinned)
            let rest = result.filter { !$0.pinned }.prefix(max(0, maxStored - pinned.count))
            result = pinned + rest
            result.sort { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
        return result
    }

    /// Text block for system instructions, or nil when empty.
    public static func render(_ facts: [MemoryFact], maxTokens: Int = promptTokens) -> String? {
        guard !facts.isEmpty else { return nil }
        var lines: [String] = []
        var used = 0
        for fact in facts.prefix(promptFacts) {
            let line = "- \(fact.text)"
            let cost = TokenEstimator.estimate(line)
            if used + cost > maxTokens, !lines.isEmpty { break }
            lines.append(line)
            used += cost
        }
        guard !lines.isEmpty else { return nil }
        return "Things you remember about the user (use naturally; do not recite as a list):\n"
            + lines.joined(separator: "\n")
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        let left = a.lowercased()
        let right = b.lowercased()
        if left == right { return true }
        if left.contains(right) || right.contains(left) { return true }
        // Same first 4 significant words → treat as update of the same fact.
        let leftWords = significantWords(left)
        let rightWords = significantWords(right)
        let shared = leftWords.prefix(4).filter { rightWords.contains($0) }.count
        return shared >= 3 && !leftWords.prefix(4).isEmpty
    }

    private static func significantWords(_ text: String) -> [String] {
        let stop: Set<String> = ["the", "a", "an", "my", "is", "are", "to", "of", "and", "for", "on", "in", "at", "i", "me", "we"]
        return text.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 1 && !stop.contains($0) }
    }
}

/// Builds / parses the on-device memory extraction call, plus a portable heuristic for tests.
public struct MemoryExtractor: Sendable {
    public init() {}

    /// Prompt that asks the model for 0–3 durable facts from the latest exchange.
    public func extractRequest(question: String, answer: String, existing: [String]) -> LLMRequest {
        var prompt = "User: \(TokenEstimator.truncate(question, toTokens: 120))\n"
            + "Assistant: \(TokenEstimator.truncate(answer, toTokens: 160))\n\n"
        if !existing.isEmpty {
            prompt += "Already remembered:\n"
                + existing.prefix(8).map { "- \($0)" }.joined(separator: "\n")
                + "\n\n"
        }
        prompt += "New facts (one per line, or NONE):"
        return LLMRequest(
            instructions: "Extract up to 3 durable personal facts worth remembering across future chats "
                + "(name, relationships, job, preferences, upcoming events, ongoing worries or goals). "
                + "Skip one-off questions, passwords, secrets, and anything already listed. "
                + "Write each fact as a short third-person sentence starting with \"User\". "
                + "If nothing durable was learned, output exactly NONE.",
            prompt: prompt
        )
    }

    /// Parse model output into candidate fact strings.
    public static func parse(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let upper = trimmed.uppercased()
        if upper == "NONE" || upper.hasPrefix("NONE\n") || upper.hasPrefix("NONE.") { return [] }
        return trimmed
            .split(whereSeparator: \.isNewline)
            .map { line in
                var text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                while let first = text.first, "-•*".contains(first) {
                    text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                if text.lowercased().hasPrefix("user ") || text.lowercased().hasPrefix("user:") {
                    // keep as-is
                }
                return text
            }
            .filter { !$0.isEmpty && $0.uppercased() != "NONE" && $0.count >= 8 }
            .prefix(3)
            .map { String($0) }
    }

    /// Cheap portable extractor used in tests and as a fallback when the model call fails.
    public static func heuristic(question: String, answer: String = "") -> [MemoryFact] {
        _ = answer
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        var facts: [MemoryFact] = []

        func capture(after prefixes: [String], category: MemoryFact.Category, template: (String) -> String) {
            for prefix in prefixes {
                guard let range = lowered.range(of: prefix) else { continue }
                let start = text.index(text.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: range.upperBound))
                var value = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".!,?"))
                guard value.count >= 2, value.count <= 80 else { continue }
                facts.append(MemoryFact(text: template(value), category: category))
                return
            }
        }

        capture(after: ["my name is ", "i'm ", "i am "], category: .person) { "User's name is \($0)" }
        // Avoid treating "I'm sad" as a name: only keep short name-like tokens for i'm/i am.
        if let last = facts.last, last.category == .person {
            let name = last.text.replacingOccurrences(of: "User's name is ", with: "")
            let emotionWords: Set<String> = ["sad", "happy", "anxious", "worried", "tired", "angry", "fine", "ok", "okay", "good", "bad"]
            if emotionWords.contains(name.lowercased()) || name.split(separator: " ").count > 4 {
                facts.removeLast()
            }
        }

        capture(after: ["i work at ", "i work for ", "my job is "], category: .person) { "User works at/as \($0)" }
        capture(after: ["i live in ", "i'm from ", "i am from "], category: .person) { "User lives in / is from \($0)" }
        capture(after: ["i prefer ", "i like my replies ", "please be "], category: .preference) { "User preference: \($0)" }

        let eventHints = ["interview", "wedding", "exam", "appointment", "flight", "deadline", "meeting"]
        if eventHints.contains(where: { lowered.contains($0) }),
           lowered.contains("my ") || lowered.contains("i have ") || lowered.contains("i've got ") || lowered.contains("tomorrow") || lowered.contains("friday") || lowered.contains("next ") {
            let snippet = TokenEstimator.truncate(text, toTokens: 40)
            facts.append(MemoryFact(text: "User mentioned: \(snippet)", category: .event))
        }

        if lowered.contains("i'm worried about ") || lowered.contains("i am worried about ") || lowered.contains("stressed about ") {
            facts.append(MemoryFact(text: "User has an ongoing concern: \(TokenEstimator.truncate(text, toTokens: 40))", category: .openLoop))
        }

        return MemoryBudget.merge(existing: [], adding: facts)
    }

    public static func categorize(_ text: String) -> MemoryFact.Category {
        let lowered = text.lowercased()
        if lowered.contains("prefer") || lowered.contains("likes") || lowered.contains("preference") { return .preference }
        if lowered.contains("interview") || lowered.contains("appointment") || lowered.contains("deadline")
            || lowered.contains("wedding") || lowered.contains("flight") || lowered.contains("meeting") { return .event }
        if lowered.contains("worried") || lowered.contains("goal") || lowered.contains("trying to") { return .openLoop }
        if lowered.contains("name") || lowered.contains("works") || lowered.contains("lives") || lowered.contains("mom")
            || lowered.contains("dad") || lowered.contains("partner") || lowered.contains("wife") || lowered.contains("husband") {
            return .person
        }
        return .other
    }
}
