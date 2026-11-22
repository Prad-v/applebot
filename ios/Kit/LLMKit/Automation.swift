import Foundation

public enum AutomationCadence: String, Sendable, Codable, CaseIterable, Identifiable {
    case daily
    case weeklySunday
    case weeklyMonday
    case weeklyFriday

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .daily: return "Every day"
        case .weeklySunday: return "Every Sunday"
        case .weeklyMonday: return "Every Monday"
        case .weeklyFriday: return "Every Friday"
        }
    }

    public func isDue(on date: Date, calendar: Calendar = .current, lastRunDayKey: String?) -> Bool {
        let key = DailyBriefBuilder.dayKey(date, calendar: calendar)
        if lastRunDayKey == key { return false }
        switch self {
        case .daily:
            return true
        case .weeklySunday:
            return calendar.component(.weekday, from: date) == 1
        case .weeklyMonday:
            return calendar.component(.weekday, from: date) == 2
        case .weeklyFriday:
            return calendar.component(.weekday, from: date) == 6
        }
    }
}

/// A local recipe that proposes a chat prompt when due (runs only after the user confirms).
public struct AutomationRecipe: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var prompt: String
    public var cadence: AutomationCadence
    public var isEnabled: Bool
    public var lastRunDayKey: String?

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        cadence: AutomationCadence = .weeklySunday,
        isEnabled: Bool = true,
        lastRunDayKey: String? = nil
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cadence = cadence
        self.isEnabled = isEnabled
        self.lastRunDayKey = lastRunDayKey
    }

    public static let templates: [AutomationRecipe] = [
        AutomationRecipe(
            title: "Sunday week plan",
            prompt: "Help me plan the week ahead. Use my calendar and reminders if connected, open loops from memory, and suggest three priorities.",
            cadence: .weeklySunday
        ),
        AutomationRecipe(
            title: "Friday wrap-up",
            prompt: "Help me do a short Friday wrap-up: what went well, what reminders are still open, and one thing to rest.",
            cadence: .weeklyFriday
        ),
        AutomationRecipe(
            title: "Morning focus",
            prompt: "Based on my calendar, due reminders, and open loops, suggest one small focus for the next hour.",
            cadence: .daily,
            isEnabled: false
        ),
    ]
}

public enum AutomationScheduler {
    public static func due(
        recipes: [AutomationRecipe],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AutomationRecipe] {
        recipes.filter { $0.isEnabled && $0.cadence.isDue(on: now, calendar: calendar, lastRunDayKey: $0.lastRunDayKey) }
    }

    public static func markRan(_ recipe: AutomationRecipe, on date: Date = Date(), calendar: Calendar = .current) -> AutomationRecipe {
        var copy = recipe
        copy.lastRunDayKey = DailyBriefBuilder.dayKey(date, calendar: calendar)
        return copy
    }
}
