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

/// Portable morning / unlock brief built from calendar + reminders + memory + profile. No network.
public struct DailyBrief: Sendable, Equatable {
    public var greeting: String
    public var agendaLines: [String]
    public var reminderLines: [String]
    public var openLoops: [String]
    public var generatedAt: Date

    public init(
        greeting: String,
        agendaLines: [String],
        reminderLines: [String] = [],
        openLoops: [String],
        generatedAt: Date = Date()
    ) {
        self.greeting = greeting
        self.agendaLines = agendaLines
        self.reminderLines = reminderLines
        self.openLoops = openLoops
        self.generatedAt = generatedAt
    }

    public var isEmpty: Bool {
        agendaLines.isEmpty && reminderLines.isEmpty && openLoops.isEmpty
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

    public static func build(
        profile: PersonalProfile,
        facts: [MemoryFact],
        events: [BriefEvent],
        reminderTitles: [String] = [],
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

        let loops = MemoryBudget.rank(facts, now: now)
            .filter { $0.category == .openLoop || ($0.category == .event && !($0.isExpired(at: now))) }
            .prefix(maxOpenLoops)
            .map(\.text)

        return DailyBrief(
            greeting: greeting,
            agendaLines: Array(agenda),
            reminderLines: Array(reminders),
            openLoops: Array(loops),
            generatedAt: now
        )
    }

    /// Calendar day key used to show the brief at most once per day.
    public static func dayKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
