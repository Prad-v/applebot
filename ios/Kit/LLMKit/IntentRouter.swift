import Foundation

/// Cheap local classification of a user message so the pipeline can skip expensive paths
/// (RAG rewrite, tools) when they are not needed under the on-device context budget.
public enum ChatIntent: String, Sendable, Codable, Equatable, CaseIterable {
    case chat
    case documents
    case calendar
    case reminders
    case health
    case email
    case liveData
    case emotional
    case rewrite

    public var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .documents: return "Documents"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .health: return "Health"
        case .email: return "Email"
        case .liveData: return "Live data"
        case .emotional: return "Emotional"
        case .rewrite: return "Rewrite"
        }
    }

    /// Whether connector tools may help. Tools stay available for open-ended chat
    /// (natural phrasing is hard to classify); rewrite skips them, and grounded
    /// document answers already omit tools in the pipeline.
    public var wantsTools: Bool {
        switch self {
        case .rewrite: return false
        case .chat, .calendar, .reminders, .health, .email, .liveData, .emotional, .documents: return true
        }
    }

    /// Whether document retrieval should run (when the chat has documents enabled).
    /// Casual `.chat` skips RAG to save the on-device window; turn on “Use my documents”
    /// and ask a factual / doc question to get `.documents`.
    public var wantsDocuments: Bool {
        switch self {
        case .documents: return true
        case .chat, .calendar, .reminders, .health, .email, .liveData, .emotional, .rewrite: return false
        }
    }
}

/// Keyword / cue based router. No model call — keeps the first turn snappy on-device.
public struct IntentRouter: Sendable {
    public init() {}

    public func route(
        question: String,
        useDocuments: Bool,
        emotion: EmotionReading? = nil,
        cue: CompanionCue = .none
    ) -> ChatIntent {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()

        if cue == .askingAboutBot || emotion?.needsSupport == true {
            return .emotional
        }

        if Self.looksLikeRewrite(lowered) {
            return .rewrite
        }

        if Self.matches(lowered, anyOf: Self.calendarHints) {
            return .calendar
        }
        if Self.matches(lowered, anyOf: Self.remindersHints) {
            return .reminders
        }
        if Self.matches(lowered, anyOf: Self.healthHints) {
            return .health
        }
        if Self.matches(lowered, anyOf: Self.emailHints) {
            return .email
        }
        if Self.matches(lowered, anyOf: Self.liveDataHints) {
            return .liveData
        }

        if useDocuments, Self.looksLikeDocumentQuestion(lowered) {
            return .documents
        }

        // Soft emotional without crisis: still prefer conversation over RAG.
        if let emotion, emotion.emotion != .neutral, emotion.intensity >= 2 {
            return .emotional
        }

        // Documents enabled + factual question with no strong other signal → try docs.
        if useDocuments, Self.looksFactual(lowered) {
            return .documents
        }

        return .chat
    }

    private static func looksLikeRewrite(_ lowered: String) -> Bool {
        let prefixes = [
            "rewrite ", "rewrite:", "make this sound like me", "in my voice",
            "polish this", "edit this", "rephrase ", "reword ",
        ]
        return prefixes.contains(where: { lowered.hasPrefix($0) || lowered.contains($0) })
            || (lowered.contains("sound like me") && lowered.count < 400)
    }

    private static func looksLikeDocumentQuestion(_ lowered: String) -> Bool {
        let hints = [
            "according to my", "in my documents", "in my notes", "in the pdf",
            "from my files", "what did i write", "my document", "the guide",
            "the manual", "based on my", "in my pdf", "from my notes",
            "my handbook", "my policy", "search my documents", "search my notes",
            "in the document", "from the document",
        ]
        return matches(lowered, anyOf: hints)
    }

    private static func looksFactual(_ lowered: String) -> Bool {
        let starters = [
            "what ", "who ", "when ", "where ", "how ", "why ", "which ",
            "summarize ", "summarise ", "find ", "look up ", "explain ",
            "can you find ", "could you find ", "do you know what ", "tell me what ",
            "what's the ", "whats the ", "what is the ",
        ]
        return starters.contains(where: { lowered.hasPrefix($0) })
    }

    private static func matches(_ text: String, anyOf hints: [String]) -> Bool {
        hints.contains { text.contains($0) }
    }

    private static let calendarHints = [
        "calendar", "schedule", "what's on", "whats on", "what is on", "am i free", "availability",
        "meeting tomorrow", "add an event", "add event", "add lunch", "book a", "my agenda",
        "on my calendar", "today's agenda", "todays agenda",
    ]

    private static let remindersHints = [
        "reminder", "reminders", "to-do", "todo", "to do", "task list", "my tasks",
        "what's due", "whats due", "mark done", "mark complete", "add a reminder",
        "remind me", "open tasks",
    ]

    private static let healthHints = [
        "apple health", "healthkit", "health kit", "health record", "health records",
        "how many steps", "my steps", "step count", "heart rate", "resting heart",
        "how did i sleep", "how i slept", "my sleep", "blood pressure", "blood oxygen",
        "spo2", "my workout", "my workouts", "active energy", "calories burned",
        "my weight", "allergies", "medications", "medication", "my meds", "pill",
        "side effect", "wellness score", "lab results", "immunization",
        "from health", "in health app",
    ]

    private static let emailHints = [
        "email", "gmail", "inbox", "reply to", "draft a reply", "message from",
    ]

    private static let liveDataHints = [
        "weather", "forecast", "temperature", "stock", "ticker", "share price",
        "watchlist", "portfolio", "share price alert", "earnings",
        "search the web", "look online", "latest news", "what did the",
        "where am i", "where am i?", "gps", "coordinates", "my location",
        "waypoint", "bearing", "compass", "breadcrumb", "trailhead",
        "offline map", "map pack", "i'm lost", "im lost", "navigate",
        "sitting too long", "been sitting", "sedentary", "motion activity",
        "have i been sitting", "too sedentary",
    ]
}
