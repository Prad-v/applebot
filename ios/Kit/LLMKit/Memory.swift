import Foundation

/// A durable fact remembered across chats. Lives only on the device.
public struct MemoryFact: Sendable, Codable, Equatable, Identifiable, Hashable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case person
        case preference
        case event
        case openLoop
        case place
        case project
        case other

        public var displayName: String {
            switch self {
            case .person: return "Person"
            case .preference: return "Preference"
            case .event: return "Event"
            case .openLoop: return "Open loop"
            case .place: return "Place"
            case .project: return "Project"
            case .other: return "Other"
            }
        }

        /// Higher = more useful in a typical companion prompt.
        public var rankWeight: Double {
            switch self {
            case .person: return 1.0
            case .preference: return 0.95
            case .openLoop: return 0.9
            case .project: return 0.85
            case .event: return 0.8
            case .place: return 0.7
            case .other: return 0.5
            }
        }
    }

    public var id: UUID
    public var text: String
    public var category: Category
    public var updatedAt: Date
    public var pinned: Bool
    /// 0...1 model/heuristic confidence. Ranked into the prompt by score.
    public var confidence: Double
    /// Optional expiry (events and time-bound open loops). Expired facts are dropped from prompts.
    public var expiresAt: Date?
    /// Bumped when the fact is injected into a prompt so recently used facts stay warm.
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        text: String,
        category: Category = .other,
        updatedAt: Date = Date(),
        pinned: Bool = false,
        confidence: Double = 0.7,
        expiresAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.category = category
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.confidence = min(max(confidence, 0), 1)
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt < now
    }
}

/// Merges, ranks and renders memory facts for the prompt.
public enum MemoryBudget {
    /// Soft cap on how many facts are kept in the store.
    public static let maxStored = 60
    /// Soft token budget for the "Things you remember" block (shared with profile via PersonalContextBudget).
    public static let promptTokens = 120
    /// Max facts injected into one prompt.
    public static let promptFacts = 12
    /// Default lifetime for event facts when the extractor does not set one.
    public static let defaultEventLifetime: TimeInterval = 14 * 24 * 60 * 60
    /// Default lifetime for open-loop facts.
    public static let defaultOpenLoopLifetime: TimeInterval = 45 * 24 * 60 * 60

    /// Prefer pinned, then score, then newest. Drops near-duplicates (case-insensitive containment).
    public static func merge(existing: [MemoryFact], adding candidates: [MemoryFact], now: Date = Date()) -> [MemoryFact] {
        var result = existing.filter { !$0.isExpired(at: now) || $0.pinned }
        for candidate in candidates {
            let cleaned = candidate.text
            guard cleaned.count >= 8, cleaned.count <= 180 else { continue }
            if candidate.isExpired(at: now), !candidate.pinned { continue }
            if let index = result.firstIndex(where: { similar($0.text, cleaned) }) {
                var updated = result[index]
                // Prefer the longer / newer wording.
                if cleaned.count >= updated.text.count {
                    updated.text = cleaned
                    updated.category = candidate.category
                }
                updated.updatedAt = candidate.updatedAt
                updated.confidence = max(updated.confidence, candidate.confidence)
                if let expires = candidate.expiresAt {
                    updated.expiresAt = expires
                } else if updated.expiresAt == nil {
                    updated.expiresAt = defaultExpiry(for: updated.category, from: now)
                }
                result[index] = updated
            } else {
                var fact = candidate
                if fact.expiresAt == nil {
                    // Lifetime starts from "now" so back-dated updatedAt values do not expire immediately.
                    fact.expiresAt = defaultExpiry(for: fact.category, from: now)
                }
                result.append(fact)
            }
        }
        result = rank(result, now: now)
        if result.count > maxStored {
            let pinned = result.filter(\.pinned)
            let rest = result.filter { !$0.pinned }.prefix(max(0, maxStored - pinned.count))
            result = rank(pinned + rest, now: now)
        }
        return result
    }

    /// Rank for prompt injection: drop expired (unless pinned), then score.
    public static func rank(_ facts: [MemoryFact], now: Date = Date()) -> [MemoryFact] {
        facts
            .filter { $0.pinned || !$0.isExpired(at: now) }
            .sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
                let left = score(lhs, now: now)
                let right = score(rhs, now: now)
                if left != right { return left > right }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    /// Ranking score used for prompt selection.
    public static func score(_ fact: MemoryFact, now: Date = Date()) -> Double {
        var value = fact.category.rankWeight * 100
        value += fact.confidence * 40
        if fact.pinned { value += 1_000 }
        let touch = fact.lastUsedAt ?? fact.updatedAt
        let ageDays = max(0, now.timeIntervalSince(touch) / 86_400)
        value += max(0, 30 - ageDays) // recency boost fades over ~a month
        if let expiresAt = fact.expiresAt {
            let daysLeft = expiresAt.timeIntervalSince(now) / 86_400
            if daysLeft < 3 { value += 15 } // soon-expiring events stay visible
        }
        return value
    }

    /// Text block for system instructions, or nil when empty.
    public static func render(
        _ facts: [MemoryFact],
        maxTokens: Int = promptTokens,
        now: Date = Date()
    ) -> String? {
        let ranked = rank(facts, now: now)
        guard !ranked.isEmpty else { return nil }
        var lines: [String] = []
        var used = 0
        for fact in ranked.prefix(promptFacts) {
            let line = "- [\(fact.category.rawValue)] \(fact.text)"
            let cost = TokenEstimator.estimate(line)
            if used + cost > maxTokens, !lines.isEmpty { break }
            lines.append(line)
            used += cost
        }
        guard !lines.isEmpty else { return nil }
        return "Things you remember about the user (use naturally; do not recite as a list):\n"
            + lines.joined(separator: "\n")
    }

    /// Mark the facts that were selected for a prompt as recently used.
    public static func markUsed(_ facts: [MemoryFact], injected texts: Set<String>, at now: Date = Date()) -> [MemoryFact] {
        facts.map { fact in
            var copy = fact
            if texts.contains(fact.text) {
                copy.lastUsedAt = now
            }
            return copy
        }
    }

    public static func defaultExpiry(for category: MemoryFact.Category, from date: Date) -> Date? {
        switch category {
        case .event:
            return date.addingTimeInterval(defaultEventLifetime)
        case .openLoop:
            return date.addingTimeInterval(defaultOpenLoopLifetime)
        default:
            return nil
        }
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
                + "(name, relationships, job, preferences, upcoming events, ongoing worries or goals, places, projects). "
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
                return text
            }
            .filter { !$0.isEmpty && $0.uppercased() != "NONE" && $0.count >= 8 }
            .prefix(3)
            .map { String($0) }
    }

    /// Cheap portable extractor used in tests and as a fallback when the model call fails.
    public static func heuristic(question: String, answer: String = "", now: Date = Date()) -> [MemoryFact] {
        _ = answer
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        var facts: [MemoryFact] = []

        func capture(after prefixes: [String], category: MemoryFact.Category, confidence: Double, template: (String) -> String) {
            for prefix in prefixes {
                guard let range = lowered.range(of: prefix) else { continue }
                let start = text.index(text.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: range.upperBound))
                var value = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".!,?"))
                guard value.count >= 2, value.count <= 80 else { continue }
                facts.append(MemoryFact(
                    text: template(value),
                    category: category,
                    confidence: confidence,
                    expiresAt: MemoryBudget.defaultExpiry(for: category, from: now)
                ))
                return
            }
        }

        capture(after: ["my name is ", "i'm ", "i am "], category: .person, confidence: 0.9) { "User's name is \($0)" }
        // Avoid treating "I'm sad" as a name: only keep short name-like tokens for i'm/i am.
        if let last = facts.last, last.category == .person {
            let name = last.text.replacingOccurrences(of: "User's name is ", with: "")
            let emotionWords: Set<String> = ["sad", "happy", "anxious", "worried", "tired", "angry", "fine", "ok", "okay", "good", "bad"]
            if emotionWords.contains(name.lowercased()) || name.split(separator: " ").count > 4 {
                facts.removeLast()
            }
        }

        capture(after: ["i work at ", "i work for ", "my job is "], category: .person, confidence: 0.85) { "User works at/as \($0)" }
        capture(after: ["i live in ", "i'm from ", "i am from "], category: .place, confidence: 0.85) { "User lives in / is from \($0)" }
        capture(after: ["i prefer ", "i like my replies ", "please be "], category: .preference, confidence: 0.75) { "User preference: \($0)" }
        capture(after: ["i'm working on ", "i am working on ", "my project "], category: .project, confidence: 0.8) { "User project: \($0)" }

        let eventHints = ["interview", "wedding", "exam", "appointment", "flight", "deadline", "meeting"]
        if eventHints.contains(where: { lowered.contains($0) }),
           lowered.contains("my ") || lowered.contains("i have ") || lowered.contains("i've got ") || lowered.contains("tomorrow") || lowered.contains("friday") || lowered.contains("next ") {
            let snippet = TokenEstimator.truncate(text, toTokens: 40)
            facts.append(MemoryFact(
                text: "User mentioned: \(snippet)",
                category: .event,
                confidence: 0.7,
                expiresAt: now.addingTimeInterval(MemoryBudget.defaultEventLifetime)
            ))
        }

        if lowered.contains("i'm worried about ") || lowered.contains("i am worried about ") || lowered.contains("stressed about ") {
            facts.append(MemoryFact(
                text: "User has an ongoing concern: \(TokenEstimator.truncate(text, toTokens: 40))",
                category: .openLoop,
                confidence: 0.75,
                expiresAt: now.addingTimeInterval(MemoryBudget.defaultOpenLoopLifetime)
            ))
        }

        return MemoryBudget.merge(existing: [], adding: facts, now: now)
    }

    public static func categorize(_ text: String) -> MemoryFact.Category {
        let lowered = text.lowercased()
        if lowered.contains("prefer") || lowered.contains("likes") || lowered.contains("preference") { return .preference }
        if lowered.contains("interview") || lowered.contains("appointment") || lowered.contains("deadline")
            || lowered.contains("wedding") || lowered.contains("flight") || lowered.contains("meeting") { return .event }
        if lowered.contains("worried") || lowered.contains("goal") || lowered.contains("trying to") { return .openLoop }
        if lowered.contains("project") || lowered.contains("building") || lowered.contains("shipping") { return .project }
        if lowered.contains("lives") || lowered.contains("city") || lowered.contains("from ") { return .place }
        if lowered.contains("name") || lowered.contains("works") || lowered.contains("mom")
            || lowered.contains("dad") || lowered.contains("partner") || lowered.contains("wife") || lowered.contains("husband") {
            return .person
        }
        return .other
    }

    /// Build a fact with category, confidence and default expiry from extracted text.
    public static func fact(from text: String, now: Date = Date(), confidence: Double = 0.75) -> MemoryFact {
        let category = categorize(text)
        return MemoryFact(
            text: text,
            category: category,
            confidence: confidence,
            expiresAt: MemoryBudget.defaultExpiry(for: category, from: now)
        )
    }
}
