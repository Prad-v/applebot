import Foundation

/// A calendar-like event summarized for the morning brief (keeps LLMKit free of EventKit).
public struct BriefEvent: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
    }
}

/// Portable morning / unlock brief built from calendar + reminders + memory + profile (+ optional health/markets). No network.
public struct DailyBrief: Sendable, Equatable {
    public var greeting: String
    public var agendaLines: [String]
    public var reminderLines: [String]
    public var healthLines: [String]
    public var marketLines: [String]
    public var openLoops: [String]
    public var generatedAt: Date

    public init(
        greeting: String,
        agendaLines: [String],
        reminderLines: [String] = [],
        healthLines: [String] = [],
        marketLines: [String] = [],
        openLoops: [String],
        generatedAt: Date = Date()
    ) {
        self.greeting = greeting
        self.agendaLines = agendaLines
        self.reminderLines = reminderLines
        self.healthLines = healthLines
        self.marketLines = marketLines
        self.openLoops = openLoops
        self.generatedAt = generatedAt
    }

    public var isEmpty: Bool {
        agendaLines.isEmpty && reminderLines.isEmpty && healthLines.isEmpty && marketLines.isEmpty && openLoops.isEmpty
    }

    public var markdown: String {
        var parts = [greeting, ""]
        if agendaLines.isEmpty {
            parts.append("**Today:** nothing on the calendar (or Calendar is off).")
        } else {
            parts.append("**Today:**")
            parts.append(contentsOf: agendaLines.map { "- \($0)" })
        }
        if !reminderLines.isEmpty {
            parts.append("")
            parts.append("**Reminders:**")
            parts.append(contentsOf: reminderLines.prefix(6).map { "- \($0)" })
        }
        if !healthLines.isEmpty {
            parts.append("")
            parts.append("**Health:**")
            parts.append(contentsOf: healthLines.prefix(6).map { "- \($0)" })
        }
        if !marketLines.isEmpty {
            parts.append("")
            parts.append("**Markets:**")
            parts.append(contentsOf: marketLines.prefix(DailyBriefBuilder.maxMarketLines).map { "- \($0)" })
        }
        if !openLoops.isEmpty {
            parts.append("")
            parts.append("**Open loops:**")
            parts.append(contentsOf: openLoops.prefix(4).map { "- \($0)" })
        }
        return parts.joined(separator: "\n")
    }
}

public enum DailyBriefBuilder {
    public static let maxEvents = 8
    public static let maxReminders = 6
    public static let maxOpenLoops = 4

    public static let maxHealthLines = 6
    public static let maxMarketLines = 4

    public static func build(
        profile: PersonalProfile,
        facts: [MemoryFact],
        events: [BriefEvent],
        reminderTitles: [String] = [],
        healthLines: [String] = [],
        marketLines: [String] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyBrief {
        let name = profile.displayName
        let hour = calendar.component(.hour, from: now)
        let partOfDay: String
        switch hour {
        case 5..<12: partOfDay = "Good morning"
        case 12..<17: partOfDay = "Good afternoon"
        default: partOfDay = "Good evening"
        }
        let greeting = name.map { "\(partOfDay), \($0)." } ?? "\(partOfDay)."

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"

        let agenda = events.prefix(maxEvents).map { event -> String in
            var line: String
            if event.isAllDay {
                line = "All day · \(event.title)"
            } else {
                line = "\(formatter.string(from: event.start)) · \(event.title)"
            }
            if let location = event.location, !location.isEmpty {
                line += " (\(location))"
            }
            return line
        }

        let reminders = reminderTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxReminders)
            .map { String($0) }

        let health = healthLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxHealthLines)
            .map { String($0) }

        let markets = marketLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxMarketLines)
            .map { String($0) }

        let loops = MemoryBudget.rank(facts, now: now)
            .filter { $0.category == .openLoop || ($0.category == .event && !($0.isExpired(at: now))) }
            .prefix(maxOpenLoops)
            .map(\.text)

        return DailyBrief(
            greeting: greeting,
            agendaLines: Array(agenda),
            reminderLines: Array(reminders),
            healthLines: Array(health),
            marketLines: Array(markets),
            openLoops: Array(loops),
            generatedAt: now
        )
    }

    /// Compact watchlist mover lines for the unlock brief (delayed quotes; not advice).
    public static func marketLines(
        quotes: [StockQuoteSnapshot],
        session: MarketSession = MarketSession.usEquity()
    ) -> [String] {
        guard !quotes.isEmpty else { return [] }
        var lines: [String] = ["US session: \(session.displayName) (heuristic)"]
        let sorted = quotes.sorted { abs($0.changePercent ?? 0) > abs($1.changePercent ?? 0) }
        let up = sorted.filter { ($0.changePercent ?? 0) > 0 }.count
        let down = sorted.filter { ($0.changePercent ?? 0) < 0 }.count
        lines.append("Watchlist: \(up) up, \(down) down of \(quotes.count)")
        for quote in sorted.prefix(2) {
            lines.append(quote.summaryLine)
        }
        return Array(lines.prefix(maxMarketLines))
    }

    /// Compact lines from a health summary for the unlock brief (no diagnosis).
    public static func healthLines(
        steps: Double? = nil,
        sleepHours: Double? = nil,
        restingHeartRate: Double? = nil,
        wellnessScore: Int? = nil,
        dueMedications: [String] = []
    ) -> [String] {
        var lines: [String] = []
        if let score = wellnessScore {
            lines.append("Wellness score \(score)/100 (local formula)")
        }
        if let sleep = sleepHours {
            lines.append(String(format: "Sleep %.1f h", sleep))
        }
        if let steps {
            lines.append("\(Int(steps.rounded())) steps so far")
        }
        if let rhr = restingHeartRate {
            lines.append(String(format: "Resting HR %.0f bpm", rhr))
        }
        if !dueMedications.isEmpty {
            lines.append("Med reminders on: " + dueMedications.prefix(4).joined(separator: ", "))
        }
        return lines
    }

    /// Calendar day key used to show the brief at most once per day.
    public static func dayKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
