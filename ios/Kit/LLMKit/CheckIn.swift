import Foundation

/// A gentle proactive check-in about an ongoing concern (relationship continuity).
public struct CheckInSuggestion: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var factID: UUID
    public var prompt: String
    public var factText: String

    public init(id: UUID = UUID(), factID: UUID, prompt: String, factText: String) {
        self.id = id
        self.factID = factID
        self.prompt = prompt
        self.factText = factText
    }
}

/// Picks open loops / near-term events that deserve a soft revisit.
public enum CheckInPlanner {
    public static let minDaysBetween = 3
    public static let maxSuggestions = 1

    public static func suggest(
        facts: [MemoryFact],
        lastCheckInAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CheckInSuggestion? {
        if let last = lastCheckInAt {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day ?? 0
            if days < minDaysBetween { return nil }
        }

        let candidates = MemoryBudget.rank(facts, now: now).filter { fact in
            guard !fact.isExpired(at: now) || fact.pinned else { return false }
            switch fact.category {
            case .openLoop: return true
            case .event:
                // Only soon / recent events.
                if let expires = fact.expiresAt {
                    return expires.timeIntervalSince(now) < 7 * 86_400
                }
                return true
            default:
                return false
            }
        }

        guard let fact = candidates.first else { return nil }
        let prompt: String
        switch fact.category {
        case .openLoop:
            prompt = "Earlier you mentioned something on your mind: \(shorten(fact.text)). Want to revisit that?"
        case .event:
            prompt = "You had this coming up: \(shorten(fact.text)). How did it go, or want to prepare?"
        default:
            prompt = "Want to catch up on: \(shorten(fact.text))?"
        }
        return CheckInSuggestion(factID: fact.id, prompt: prompt, factText: fact.text)
    }

    private static func shorten(_ text: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: "User has an ongoing concern: ", with: "")
            .replacingOccurrences(of: "User mentioned: ", with: "")
        return TokenEstimator.truncate(trimmed, toTokens: 28)
    }
}
