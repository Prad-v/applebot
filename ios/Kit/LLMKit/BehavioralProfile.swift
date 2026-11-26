import Foundation

/// Interest category inferred from chat questions and tool use (on-device only).
public enum BehavioralInterest: String, Sendable, Codable, CaseIterable, Identifiable {
    case travel
    case fitness
    case work
    case finance
    case food
    case health
    case tech
    case shopping
    case entertainment
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .travel: return "Travel"
        case .fitness: return "Fitness"
        case .work: return "Work"
        case .finance: return "Finance"
        case .food: return "Food"
        case .health: return "Health"
        case .tech: return "Tech"
        case .shopping: return "Shopping"
        case .entertainment: return "Entertainment"
        case .other: return "Other"
        }
    }
}

/// One day's summarized sensor / calendar signals used to refresh routines.
public struct BehavioralDaySample: Sendable, Codable, Equatable {
    public var day: Date
    public var sleepHours: Double?
    public var steps: Double?
    public var workoutCount: Int
    /// Local hour (0–23) of the first non-all-day calendar event, if any.
    public var firstEventHour: Int?
    /// Local hour (0–23) of the last non-all-day calendar event end, if any.
    public var lastEventHour: Int?

    public init(
        day: Date,
        sleepHours: Double? = nil,
        steps: Double? = nil,
        workoutCount: Int = 0,
        firstEventHour: Int? = nil,
        lastEventHour: Int? = nil
    ) {
        self.day = day
        self.sleepHours = sleepHours
        self.steps = steps
        self.workoutCount = max(0, workoutCount)
        self.firstEventHour = firstEventHour.map { min(max($0, 0), 23) }
        self.lastEventHour = lastEventHour.map { min(max($0, 0), 23) }
    }
}

/// One chat turn used to update interests, stress, travel, and spending hints.
public struct BehavioralTurnSignal: Sendable, Equatable {
    public var question: String
    public var intent: ChatIntent?
    public var emotion: Emotion
    public var intensity: Int
    public var toolsUsed: [String]
    public var searchQuery: String?

    public init(
        question: String,
        intent: ChatIntent? = nil,
        emotion: Emotion = .neutral,
        intensity: Int = 0,
        toolsUsed: [String] = [],
        searchQuery: String? = nil
    ) {
        self.question = question
        self.intent = intent
        self.emotion = emotion
        self.intensity = intensity
        self.toolsUsed = toolsUsed
        self.searchQuery = searchQuery
    }
}

/// Ranked interest with a hit count (kept compact for prompts).
public struct InterestSignal: Sendable, Codable, Equatable, Identifiable {
    public var id: String { topic.rawValue }
    public var topic: BehavioralInterest
    public var count: Int

    public init(topic: BehavioralInterest, count: Int) {
        self.topic = topic
        self.count = max(0, count)
    }
}

/// Rolling observation log that feeds the summarized behavioral profile.
public struct BehavioralObservationLog: Sendable, Codable, Equatable {
    public static let maxDaySamples = 14
    public static let maxTopicKeys = 12

    public var daySamples: [BehavioralDaySample]
    public var interestCounts: [String: Int]
    public var travelMentions: Int
    public var stressEpisodes: Int
    public var stressWithShortSleep: Int
    public var spendingKeywordHits: Int
    public var lastTurnAt: Date?

    public init(
        daySamples: [BehavioralDaySample] = [],
        interestCounts: [String: Int] = [:],
        travelMentions: Int = 0,
        stressEpisodes: Int = 0,
        stressWithShortSleep: Int = 0,
        spendingKeywordHits: Int = 0,
        lastTurnAt: Date? = nil
    ) {
        self.daySamples = daySamples
        self.interestCounts = interestCounts
        self.travelMentions = max(0, travelMentions)
        self.stressEpisodes = max(0, stressEpisodes)
        self.stressWithShortSleep = max(0, stressWithShortSleep)
        self.spendingKeywordHits = max(0, spendingKeywordHits)
        self.lastTurnAt = lastTurnAt
    }

    public var isEmpty: Bool {
        daySamples.isEmpty && interestCounts.isEmpty && travelMentions == 0
            && stressEpisodes == 0 && spendingKeywordHits == 0
    }
}

/// Compact behavioral twin card: routines, interests, stress, spending hints.
/// Injected into chat as a small prompt block — not a model fine-tune.
public struct BehavioralProfile: Sendable, Codable, Equatable {
    public var isEnabled: Bool
    public var typicalSleepHours: Double?
    public var exerciseDaysPerWeek: Double?
    public var typicalSteps: Double?
    public var workdayStartHour: Int?
    public var workdayEndHour: Int?
    public var topInterests: [InterestSignal]
    public var travelAffinity: Double?
    public var stressNote: String?
    public var spendingNote: String?
    public var sampleDays: Int
    public var updatedAt: Date?
    public var log: BehavioralObservationLog

    public static let empty = BehavioralProfile()

    public init(
        isEnabled: Bool = true,
        typicalSleepHours: Double? = nil,
        exerciseDaysPerWeek: Double? = nil,
        typicalSteps: Double? = nil,
        workdayStartHour: Int? = nil,
        workdayEndHour: Int? = nil,
        topInterests: [InterestSignal] = [],
        travelAffinity: Double? = nil,
        stressNote: String? = nil,
        spendingNote: String? = nil,
        sampleDays: Int = 0,
        updatedAt: Date? = nil,
        log: BehavioralObservationLog = BehavioralObservationLog()
    ) {
        self.isEnabled = isEnabled
        self.typicalSleepHours = typicalSleepHours
        self.exerciseDaysPerWeek = exerciseDaysPerWeek
        self.typicalSteps = typicalSteps
        self.workdayStartHour = workdayStartHour.map { min(max($0, 0), 23) }
        self.workdayEndHour = workdayEndHour.map { min(max($0, 0), 23) }
        self.topInterests = Array(topInterests.prefix(Self.maxInterests))
        self.travelAffinity = travelAffinity.map { min(max($0, 0), 1) }
        self.stressNote = stressNote.map { String($0.prefix(120)) }
        self.spendingNote = spendingNote.map { String($0.prefix(120)) }
        self.sampleDays = max(0, sampleDays)
        self.updatedAt = updatedAt
        self.log = log
    }

    public static let maxInterests = 5
    public static let promptTokens = 100

    public var hasSummary: Bool {
        typicalSleepHours != nil
            || exerciseDaysPerWeek != nil
            || workdayStartHour != nil
            || !topInterests.isEmpty
            || travelAffinity != nil
            || stressNote != nil
            || spendingNote != nil
    }

    public var isEmpty: Bool { !hasSummary && log.isEmpty }

    /// Compact instruction block, or nil when disabled / empty.
    public func render(maxTokens: Int = promptTokens) -> String? {
        guard isEnabled, hasSummary else { return nil }
        var lines: [String] = []
        if let typicalSleepHours {
            lines.append(String(format: "- Typical sleep: %.1fh / night", typicalSleepHours))
        }
        if let exerciseDaysPerWeek {
            var exercise = String(format: "- Exercise: ~%.1f days / week", exerciseDaysPerWeek)
            if let typicalSteps {
                exercise += String(format: " · ~%.0f steps/day", typicalSteps)
            }
            lines.append(exercise)
        } else if let typicalSteps {
            lines.append(String(format: "- Typical steps: ~%.0f / day", typicalSteps))
        }
        if let start = workdayStartHour, let end = workdayEndHour {
            lines.append(String(format: "- Workday calendar window: %02d:00–%02d:00", start, end))
        } else if let start = workdayStartHour {
            lines.append(String(format: "- Typical first meeting ~%02d:00", start))
        }
        if !topInterests.isEmpty {
            let names = topInterests.prefix(Self.maxInterests).map(\.topic.displayName).joined(separator: ", ")
            lines.append("- Often asks about: \(names)")
        }
        if let travelAffinity, travelAffinity >= 0.35 {
            let level = travelAffinity >= 0.65 ? "high" : "moderate"
            lines.append("- Travel interest: \(level)")
        }
        if let stressNote, !stressNote.isEmpty {
            lines.append("- Stress pattern: \(TokenEstimator.truncate(stressNote, toTokens: 28))")
        }
        if let spendingNote, !spendingNote.isEmpty {
            lines.append("- Spending hints: \(TokenEstimator.truncate(spendingNote, toTokens: 24))")
        }
        guard !lines.isEmpty else { return nil }

        var kept: [String] = []
        var used = 0
        let header = "Behavioral patterns (use naturally; do not recite as a list):"
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
}

/// Builds / updates the behavioral profile from day samples and chat turns.
public enum BehavioralSummarizer {
    public static let minDaysForSleep = 3
    public static let minDaysForExercise = 3
    public static let minDaysForOffice = 3
    public static let shortSleepHours = 6.0

    /// Merge day samples (health / calendar) and recompute routine fields.
    public static func ingestDays(_ samples: [BehavioralDaySample], into profile: BehavioralProfile, now: Date = Date()) -> BehavioralProfile {
        var next = profile
        var log = next.log
        for sample in samples {
            if let index = log.daySamples.firstIndex(where: { Calendar.current.isDate($0.day, inSameDayAs: sample.day) }) {
                log.daySamples[index] = mergeDay(log.daySamples[index], with: sample)
            } else {
                log.daySamples.append(sample)
            }
        }
        log.daySamples.sort { $0.day > $1.day }
        if log.daySamples.count > BehavioralObservationLog.maxDaySamples {
            log.daySamples = Array(log.daySamples.prefix(BehavioralObservationLog.maxDaySamples))
        }
        next.log = log
        return recompute(next, now: now)
    }

    /// Record a chat turn: interests, travel, stress, spending.
    public static func ingestTurn(_ turn: BehavioralTurnSignal, into profile: BehavioralProfile, now: Date = Date()) -> BehavioralProfile {
        var next = profile
        var log = next.log
        log.lastTurnAt = now

        let topics = classifyInterests(question: turn.question, intent: turn.intent, tools: turn.toolsUsed, searchQuery: turn.searchQuery)
        for topic in topics {
            log.interestCounts[topic.rawValue, default: 0] += 1
        }
        if log.interestCounts.count > BehavioralObservationLog.maxTopicKeys {
            let trimmed = log.interestCounts.sorted { $0.value > $1.value }.prefix(BehavioralObservationLog.maxTopicKeys)
            log.interestCounts = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }

        if topics.contains(.travel) || mentionsTravel(turn.question) || mentionsTravel(turn.searchQuery ?? "") {
            log.travelMentions += 1
        }

        if mentionsSpending(turn.question) || topics.contains(.shopping) || topics.contains(.finance) {
            log.spendingKeywordHits += 1
        }

        let distressed = turn.emotion.isDistress && turn.intensity >= 3
        if distressed {
            log.stressEpisodes += 1
            let recentSleep = log.daySamples.prefix(3).compactMap(\.sleepHours)
            if let avg = average(recentSleep), avg < shortSleepHours {
                log.stressWithShortSleep += 1
            }
        }

        next.log = log
        return recompute(next, now: now)
    }

    /// Recompute summary fields from the observation log.
    public static func recompute(_ profile: BehavioralProfile, now: Date = Date()) -> BehavioralProfile {
        var next = profile
        let log = next.log
        let days = log.daySamples

        let sleeps = days.compactMap(\.sleepHours)
        if sleeps.count >= minDaysForSleep {
            next.typicalSleepHours = round1(average(sleeps) ?? 0)
        }

        if days.count >= minDaysForExercise {
            let workoutDays = days.filter { $0.workoutCount > 0 }.count
            let perWeek = Double(workoutDays) / Double(max(days.count, 1)) * 7.0
            next.exerciseDaysPerWeek = round1(min(perWeek, 7))
            let steps = days.compactMap(\.steps)
            if let avgSteps = average(steps), avgSteps > 0 {
                next.typicalSteps = (avgSteps / 100).rounded() * 100
            }
        }

        let starts = days.compactMap(\.firstEventHour)
        let ends = days.compactMap(\.lastEventHour)
        if starts.count >= minDaysForOffice {
            next.workdayStartHour = medianInt(starts)
        }
        if ends.count >= minDaysForOffice {
            next.workdayEndHour = medianInt(ends)
        }

        next.topInterests = log.interestCounts
            .compactMap { key, value -> InterestSignal? in
                guard let topic = BehavioralInterest(rawValue: key), value > 0 else { return nil }
                return InterestSignal(topic: topic, count: value)
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.topic.rawValue < rhs.topic.rawValue
            }
            .prefix(BehavioralProfile.maxInterests)
            .map { $0 }

        let chatSignals = log.interestCounts.values.reduce(0, +) + log.travelMentions
        if chatSignals > 0 {
            next.travelAffinity = min(1, Double(log.travelMentions) / Double(max(chatSignals, 1)) * 4)
        }

        if log.stressEpisodes >= 2 {
            if log.stressWithShortSleep * 2 >= log.stressEpisodes {
                next.stressNote = "Often stressed when sleep has been short; prefer calm, short replies."
            } else {
                next.stressNote = "Shows stress in chat; acknowledge feelings before problem-solving."
            }
        }

        if log.spendingKeywordHits >= 3 {
            let financeHeavy = (log.interestCounts[BehavioralInterest.finance.rawValue] ?? 0)
                >= (log.interestCounts[BehavioralInterest.shopping.rawValue] ?? 0)
            next.spendingNote = financeHeavy
                ? "Often discusses money, budgets, or markets."
                : "Often discusses shopping or purchases."
        }

        next.sampleDays = days.count
        next.updatedAt = now
        return next
    }

    /// Classify interest topics from a question / tools (portable keyword rules).
    public static func classifyInterests(
        question: String,
        intent: ChatIntent? = nil,
        tools: [String] = [],
        searchQuery: String? = nil
    ) -> [BehavioralInterest] {
        let text = (question + " " + (searchQuery ?? "")).lowercased()
        var found = Set<BehavioralInterest>()

        if intent == .health || tools.contains(where: { $0.lowercased().contains("health") }) {
            found.insert(.health)
        }
        if intent == .liveData || tools.contains(where: { $0.lowercased().contains("stock") || $0.lowercased().contains("weather") || $0.lowercased().contains("search") }) {
            if tools.contains(where: { $0.lowercased().contains("stock") }) { found.insert(.finance) }
            if text.contains("weather") || text.contains("forecast") { found.insert(.travel) }
        }
        if intent == .calendar || intent == .reminders || intent == .email {
            found.insert(.work)
        }

        func hit(_ words: [String], _ topic: BehavioralInterest) {
            if words.contains(where: { text.contains($0) }) { found.insert(topic) }
        }

        hit(["flight", "trip", "travel", "hotel", "vacation", "visa", "airport", "itinerary"], .travel)
        hit(["workout", "gym", "run", "running", "exercise", "steps", "yoga", "bike", "cycling"], .fitness)
        hit(["meeting", "deadline", "office", "coworker", "standup", "sprint", "okrs"], .work)
        hit(["stock", "stocks", "portfolio", "budget", "salary", "invest", "tax", "mortgage"], .finance)
        hit(["recipe", "restaurant", "dinner", "lunch", "coffee", "cook"], .food)
        hit(["sleep", "heart rate", "medication", "wellness", "doctor", "clinic"], .health)
        hit(["iphone", "swift", "api", "code", "laptop", "software", "ai "], .tech)
        hit(["buy", "bought", "purchase", "shopping", "amazon", "order"], .shopping)
        hit(["movie", "concert", "game", "netflix", "music", "podcast"], .entertainment)

        return Array(found).sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Helpers

    private static func mergeDay(_ existing: BehavioralDaySample, with incoming: BehavioralDaySample) -> BehavioralDaySample {
        BehavioralDaySample(
            day: incoming.day,
            sleepHours: incoming.sleepHours ?? existing.sleepHours,
            steps: incoming.steps ?? existing.steps,
            workoutCount: max(existing.workoutCount, incoming.workoutCount),
            firstEventHour: incoming.firstEventHour ?? existing.firstEventHour,
            lastEventHour: incoming.lastEventHour ?? existing.lastEventHour
        )
    }

    private static func mentionsTravel(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["flight", "trip", "travel", "hotel", "vacation", "airport"].contains { lowered.contains($0) }
    }

    private static func mentionsSpending(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["spent", "spend", "budget", "expensive", "cheap", "subscription", "bought", "purchase", "salary"]
            .contains { lowered.contains($0) }
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func medianInt(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Soft token budget for the behavioral prompt block (separate from profile+memory 200).
public enum BehavioralContextBudget {
    public static let maxTokens = BehavioralProfile.promptTokens

    public static func render(_ profile: BehavioralProfile, maxTokens: Int = maxTokens) -> String? {
        profile.render(maxTokens: maxTokens)
    }
}
