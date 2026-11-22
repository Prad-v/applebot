import Foundation

/// How the user prefers replies to be shaped. Compact enough to fit the profile token budget.
public enum ReplyStyle: String, Sendable, Codable, CaseIterable, Identifiable {
    case balanced
    case concise
    case detailed
    case bullets

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .balanced: return "Balanced"
        case .concise: return "Concise"
        case .detailed: return "Detailed"
        case .bullets: return "Bullets"
        }
    }

    public var promptHint: String {
        switch self {
        case .balanced: return "Match the user's length; keep answers clear."
        case .concise: return "Prefer short answers. Skip filler."
        case .detailed: return "Give fuller answers with brief context when helpful."
        case .bullets: return "Prefer short bullet lists over long paragraphs."
        }
    }
}

/// A preference learned from chat that waits for the user to confirm before it enters the profile.
public struct PendingPreference: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var text: String
    public var proposedAt: Date

    public init(id: UUID = UUID(), text: String, proposedAt: Date = Date()) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.proposedAt = proposedAt
    }
}

/// Structured personal profile injected into prompts separately from free-form memory facts.
/// Keeps the ~200-token memory budget usable: profile gets a small fixed slice; facts get the rest.
public struct PersonalProfile: Sendable, Codable, Equatable {
    public var displayName: String?
    public var roles: [String]
    public var city: String?
    public var replyStyle: ReplyStyle
    public var boundaries: [String]
    public var confirmedPrefs: [String]
    public var pendingPrefs: [PendingPreference]

    public init(
        displayName: String? = nil,
        roles: [String] = [],
        city: String? = nil,
        replyStyle: ReplyStyle = .balanced,
        boundaries: [String] = [],
        confirmedPrefs: [String] = [],
        pendingPrefs: [PendingPreference] = []
    ) {
        self.displayName = Self.cleanOptional(displayName)
        self.roles = roles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.city = Self.cleanOptional(city)
        self.replyStyle = replyStyle
        self.boundaries = boundaries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.confirmedPrefs = confirmedPrefs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.pendingPrefs = pendingPrefs.filter { !$0.text.isEmpty }
    }

    public var isEmpty: Bool {
        displayName == nil && roles.isEmpty && city == nil
            && replyStyle == .balanced && boundaries.isEmpty && confirmedPrefs.isEmpty
    }

    /// Soft token budget for the profile block inside the memory/instruction slot.
    public static let promptTokens = 80
    public static let maxConfirmedPrefs = 8
    public static let maxBoundaries = 6
    public static let maxPending = 10

    /// Compact instruction block, or nil when there is nothing useful to say.
    public func render(maxTokens: Int = promptTokens) -> String? {
        var lines: [String] = []
        if let displayName, !displayName.isEmpty {
            lines.append("- Name: \(displayName)")
        }
        if !roles.isEmpty {
            lines.append("- Roles: \(roles.prefix(4).joined(separator: ", "))")
        }
        if let city, !city.isEmpty {
            lines.append("- City: \(city)")
        }
        if replyStyle != .balanced {
            lines.append("- Reply style: \(replyStyle.promptHint)")
        }
        for pref in confirmedPrefs.prefix(Self.maxConfirmedPrefs) {
            lines.append("- Pref: \(TokenEstimator.truncate(pref, toTokens: 24))")
        }
        for boundary in boundaries.prefix(Self.maxBoundaries) {
            lines.append("- Boundary: \(TokenEstimator.truncate(boundary, toTokens: 24))")
        }
        guard !lines.isEmpty else { return nil }

        var kept: [String] = []
        var used = 0
        let header = "User profile (follow these; do not recite as a list):"
        used += TokenEstimator.estimate(header)
        for line in lines {
            let cost = TokenEstimator.estimate(line)
            if used + cost > maxTokens, !kept.isEmpty { break }
            kept.append(line)
            used += cost
        }
        guard !kept.isEmpty else { return nil }
        return header + "\n" + kept.joined(separator: "\n")
    }

    /// Propose a preference for user confirmation (deduped against confirmed + pending).
    public mutating func proposePreference(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8, text.count <= 160 else { return }
        let lowered = text.lowercased()
        if confirmedPrefs.contains(where: { $0.lowercased() == lowered }) { return }
        if pendingPrefs.contains(where: { $0.text.lowercased() == lowered }) { return }
        pendingPrefs.insert(PendingPreference(text: text), at: 0)
        if pendingPrefs.count > Self.maxPending {
            pendingPrefs = Array(pendingPrefs.prefix(Self.maxPending))
        }
    }

    public mutating func confirmPreference(id: UUID) {
        guard let index = pendingPrefs.firstIndex(where: { $0.id == id }) else { return }
        let text = pendingPrefs.remove(at: index).text
        if !confirmedPrefs.contains(where: { $0.lowercased() == text.lowercased() }) {
            confirmedPrefs.insert(text, at: 0)
            if confirmedPrefs.count > Self.maxConfirmedPrefs {
                confirmedPrefs = Array(confirmedPrefs.prefix(Self.maxConfirmedPrefs))
            }
        }
    }

    public mutating func dismissPreference(id: UUID) {
        pendingPrefs.removeAll { $0.id == id }
    }

    public mutating func removeConfirmedPref(_ text: String) {
        confirmedPrefs.removeAll { $0 == text }
    }

    /// Pull obvious profile fields from a memory fact (name / city / job) without waiting for confirmation.
    public mutating func absorbIdentityFact(_ fact: MemoryFact) {
        let text = fact.text
        let lowered = text.lowercased()
        if displayName == nil, let name = Self.capture(after: ["user's name is ", "user is named "], in: lowered, original: text) {
            displayName = name
        }
        if city == nil, let place = Self.capture(after: ["user lives in / is from ", "user lives in ", "user is from "], in: lowered, original: text) {
            city = place
        }
        if roles.isEmpty, let role = Self.capture(after: ["user works at/as ", "user works as ", "user works at "], in: lowered, original: text) {
            roles = [role]
        }
    }

    private static func cleanOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    private static func capture(after prefixes: [String], in lowered: String, original: String) -> String? {
        for prefix in prefixes {
            guard let range = lowered.range(of: prefix) else { continue }
            let start = original.index(original.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: range.upperBound))
            var value = String(original[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".!,?"))
            guard value.count >= 2, value.count <= 80 else { continue }
            return value
        }
        return nil
    }
}

/// Combines profile + ranked memory into the instruction slot without blowing the shared budget.
public enum PersonalContextBudget {
    /// Total soft budget shared by profile + memory facts (matches historical memory slot).
    public static let totalTokens = 200

    public static func render(profile: PersonalProfile, facts: [MemoryFact], now: Date = Date()) -> String? {
        let profileBlock = profile.render(maxTokens: PersonalProfile.promptTokens)
        let profileCost = profileBlock.map { TokenEstimator.estimate($0) } ?? 0
        let factBudget = max(40, totalTokens - profileCost)
        let factBlock = MemoryBudget.render(facts, maxTokens: factBudget, now: now)
        switch (profileBlock, factBlock) {
        case (nil, nil): return nil
        case (let p?, nil): return p
        case (nil, let f?): return f
        case (let p?, let f?): return p + "\n\n" + f
        }
    }
}
