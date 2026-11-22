import Foundation
import LLMKit

/// One Reminders item, portable across EventKit and in-memory test providers.
public struct ReminderInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var notes: String?
    public var due: Date?
    public var isCompleted: Bool
    public var listName: String
    public var priority: Int

    public init(
        id: String,
        title: String,
        notes: String? = nil,
        due: Date? = nil,
        isCompleted: Bool = false,
        listName: String = "Reminders",
        priority: Int = 0
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.due = due
        self.isCompleted = isCompleted
        self.listName = listName
        self.priority = priority
    }
}

/// Source of Reminders data. `EventKitRemindersProvider` is the real one; `InMemoryRemindersProvider` for tests.
public protocol RemindersProvider: Sendable {
    func permission() async -> PermissionState
    func requestAccess() async throws -> Bool
    /// Incomplete reminders, optionally due before `dueBefore` (inclusive end of window).
    func reminders(dueBefore: Date?, incompleteOnly: Bool, limit: Int) async throws -> [ReminderInfo]
    func createReminder(title: String, due: Date?, notes: String?) async throws -> ReminderInfo
    func completeReminder(id: String) async throws -> ReminderInfo
}

public actor InMemoryRemindersProvider: RemindersProvider {
    private var state: PermissionState
    private var stored: [ReminderInfo]
    private let grantOnRequest: Bool

    public init(
        permission: PermissionState = .authorized,
        reminders: [ReminderInfo] = [],
        grantOnRequest: Bool = true
    ) {
        self.state = permission
        self.stored = reminders
        self.grantOnRequest = grantOnRequest
    }

    public func permission() -> PermissionState { state }

    public func requestAccess() -> Bool {
        if state == .notDetermined { state = grantOnRequest ? .authorized : .denied }
        return state == .authorized
    }

    public func reminders(dueBefore: Date?, incompleteOnly: Bool, limit: Int) throws -> [ReminderInfo] {
        guard state == .authorized else {
            throw ConnectorError.permissionDenied("Reminders access has not been granted.")
        }
        var list = stored
        if incompleteOnly { list = list.filter { !$0.isCompleted } }
        if let dueBefore {
            list = list.filter { reminder in
                guard let due = reminder.due else { return true } // undated incomplete stay visible
                return due <= dueBefore
            }
        }
        return Array(list.sorted { lhs, rhs in
            switch (lhs.due, rhs.due) {
            case (nil, nil): return lhs.title < rhs.title
            case (nil, _?): return false
            case (_?, nil): return true
            case (let a?, let b?): return a < b
            }
        }.prefix(limit))
    }

    public func createReminder(title: String, due: Date?, notes: String?) throws -> ReminderInfo {
        guard state == .authorized else {
            throw ConnectorError.permissionDenied("Reminders access has not been granted.")
        }
        let item = ReminderInfo(
            id: "mem-\(stored.count + 1)",
            title: title,
            notes: notes,
            due: due
        )
        stored.append(item)
        return item
    }

    public func completeReminder(id: String) throws -> ReminderInfo {
        guard state == .authorized else {
            throw ConnectorError.permissionDenied("Reminders access has not been granted.")
        }
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            throw ConnectorError.invalidArgument("No reminder found with that id.")
        }
        stored[index].isCompleted = true
        return stored[index]
    }

    public func allReminders() -> [ReminderInfo] { stored }
}

/// Reads Apple Reminders and, after approval, creates or completes them. Stays on-device.
public struct RemindersConnector: Connector {
    public let id = "reminders"
    public let displayName = "Reminders"
    public let summary = "See your to-dos, add reminders, and mark them done after you approve."
    public let symbolName = "checklist"
    public let dataNote = "Reads Reminders on this iPhone only. Details are given to the on-device model and never leave the device."
    public let hasAccount = false

    private let provider: RemindersProvider
    private let calendar: Calendar
    private let clock: @Sendable () -> Date

    public static let maxReminders = 20

    public init(
        provider: RemindersProvider,
        calendar: Calendar = .current,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.calendar = calendar
        self.clock = clock
    }

    public func status() async -> ConnectorStatus {
        switch await provider.permission() {
        case .authorized: return .connected(account: nil)
        case .notDetermined: return .notConnected
        case .denied: return .unavailable("Reminders access was denied. Allow it in Settings > Applebot.")
        case .restricted: return .unavailable("Reminders access is restricted on this device.")
        }
    }

    public func connect() async throws {
        let granted = try await provider.requestAccess()
        guard granted else {
            throw ConnectorError.permissionDenied("Reminders access was not granted. Allow it in Settings > Applebot.")
        }
    }

    public func disconnect() async {}

    /// Incomplete reminders for the morning brief (no model call). Empty when not authorized.
    public func openReminders(limit: Int = 8) async -> [ReminderInfo] {
        guard await provider.permission() == .authorized else { return [] }
        let endOfDay: Date? = {
            let start = calendar.startOfDay(for: clock())
            return calendar.date(byAdding: .day, value: 1, to: start)
        }()
        // Prefer due today / overdue / undated incomplete.
        let items = (try? await provider.reminders(dueBefore: endOfDay, incompleteOnly: true, limit: limit)) ?? []
        if !items.isEmpty { return items }
        return (try? await provider.reminders(dueBefore: nil, incompleteOnly: true, limit: limit)) ?? []
    }

    public func tools() -> [ToolSpec] {
        [listRemindersTool, createReminderTool, completeReminderTool]
    }

    // MARK: Tools

    private var listRemindersTool: ToolSpec {
        let provider = self.provider, calendar = self.calendar, clock = self.clock
        return ToolSpec(
            name: "reminders_list",
            description: "List the user's incomplete Reminders / to-dos. Use for open tasks, what is due, or what they still need to do.",
            parameters: [
                ToolParameter(
                    "scope",
                    "Which reminders: 'today' (due today or overdue, plus undated), 'week' (next 7 days), or 'all' incomplete. Defaults to today.",
                    required: false
                ),
            ],
            label: "Checking your reminders",
            handler: { arguments in
                let now = clock()
                let scope = (arguments.string("scope") ?? "today").lowercased()
                let dueBefore: Date?
                switch scope {
                case "all", "open", "incomplete":
                    dueBefore = nil
                case "week":
                    dueBefore = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now))
                default: // today
                    dueBefore = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                }
                let items = try await provider.reminders(
                    dueBefore: dueBefore, incompleteOnly: true, limit: Self.maxReminders
                )
                guard !items.isEmpty else {
                    return scope == "all"
                        ? "No incomplete reminders."
                        : "No incomplete reminders due \(scope == "week" ? "this week" : "today")."
                }
                let lines = items.map { Self.describe($0, calendar: calendar) }
                return "Incomplete reminders (\(scope)):\n" + lines.joined(separator: "\n")
            }
        )
    }

    private var createReminderTool: ToolSpec {
        let provider = self.provider, calendar = self.calendar, clock = self.clock
        return ToolSpec(
            name: "reminders_create",
            description: "Create a new reminder / to-do. The user must approve it first. Only use when they asked to remember or add a task.",
            parameters: [
                ToolParameter("title", "Short reminder title."),
                ToolParameter("due", "Optional due as YYYY-MM-DD or YYYY-MM-DD HH:mm, or 'today' / 'tomorrow'.", required: false),
                ToolParameter("notes", "Optional notes.", required: false),
            ],
            label: "Adding a reminder",
            requiresApproval: true,
            approval: { arguments in
                let title = arguments.string("title") ?? "Untitled"
                var detail = title
                if let due = arguments.string("due") { detail += "\nDue: \(due)" }
                if let notes = arguments.string("notes") { detail += "\n\(notes)" }
                return ApprovalRequest(
                    toolName: "reminders_create",
                    title: "Add this reminder?",
                    detail: detail,
                    confirmLabel: "Add reminder"
                )
            },
            handler: { arguments in
                guard let title = arguments.string("title") else {
                    throw ConnectorError.invalidArgument("A reminder needs a title.")
                }
                var due: Date?
                if let raw = arguments.string("due"),
                   let parsed = DateInput.parse(raw, now: clock(), calendar: calendar) {
                    due = parsed.date
                }
                let created = try await provider.createReminder(
                    title: String(title.prefix(200)),
                    due: due,
                    notes: arguments.string("notes").map { String($0.prefix(500)) }
                )
                return "Added reminder: " + Self.describe(created, calendar: calendar)
            }
        )
    }

    private var completeReminderTool: ToolSpec {
        let provider = self.provider, calendar = self.calendar
        return ToolSpec(
            name: "reminders_complete",
            description: "Mark a reminder complete by id from a previous reminders_list result. The user must approve. Only when they said they finished a task.",
            parameters: [
                ToolParameter("id", "Reminder id from reminders_list."),
            ],
            label: "Completing a reminder",
            requiresApproval: true,
            approval: { arguments in
                ApprovalRequest(
                    toolName: "reminders_complete",
                    title: "Mark this reminder done?",
                    detail: arguments.string("id").map { "Reminder id: \($0)" } ?? "Unknown reminder",
                    confirmLabel: "Mark done"
                )
            },
            handler: { arguments in
                guard let id = arguments.string("id") else {
                    throw ConnectorError.invalidArgument("Provide the reminder id from the list.")
                }
                let done = try await provider.completeReminder(id: id)
                return "Completed: " + Self.describe(done, calendar: calendar)
            }
        )
    }

    static func describe(_ reminder: ReminderInfo, calendar: Calendar) -> String {
        var line = "- [\(reminder.id)] \(reminder.title)"
        if let due = reminder.due {
            line += " · due \(DateInput.format(due, calendar: calendar, includeTime: true))"
        }
        if reminder.isCompleted { line += " · done" }
        if let notes = reminder.notes, !notes.isEmpty {
            line += " · \(TokenEstimator.truncate(notes, toTokens: 20))"
        }
        if reminder.listName != "Reminders" {
            line += " · \(reminder.listName)"
        }
        return line
    }
}

#if canImport(EventKit)
import EventKit

/// `RemindersProvider` backed by Apple Reminders through EventKit.
///
/// Requires `NSRemindersFullAccessUsageDescription` in Info.plist.
public final class EventKitRemindersProvider: RemindersProvider, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func permission() async -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .authorized
        case .notDetermined, .writeOnly: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    public func reminders(dueBefore: Date?, incompleteOnly: Bool, limit: Int) async throws -> [ReminderInfo] {
        guard await permission() == .authorized else {
            throw ConnectorError.permissionDenied("Reminders access has not been granted.")
        }
        let predicate = store.predicateForReminders(in: nil)
        // Map to Sendable ReminderInfo inside the EventKit callback — EKReminder is not Sendable.
        var items: [ReminderInfo] = try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.info))
            }
        }
        if incompleteOnly { items = items.filter { !$0.isCompleted } }
        if let dueBefore {
            items = items.filter { reminder in
                guard let due = reminder.due else { return true }
                return due <= dueBefore
            }
        }
        return Array(items.sorted { lhs, rhs in
            switch (lhs.due, rhs.due) {
            case (nil, nil): return lhs.title < rhs.title
            case (nil, _?): return false
            case (_?, nil): return true
            case (let a?, let b?): return a < b
            }
        }.prefix(limit))
    }

    public func createReminder(title: String, due: Date?, notes: String?) async throws -> ReminderInfo {
        guard await permission() == .authorized else {
            throw ConnectorError.permissionDenied("Reminders access has not been granted.")
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw ConnectorError.unexpectedResponse("There is no Reminders list that can accept new items.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
        }
        try store.save(reminder, commit: true)
        return Self.info(reminder)
    }

    public func completeReminder(id: String) async throws -> ReminderInfo {
        guard await permission() == .authorized else {
            throw ConnectorError.permissionDenied("Reminders access has not been granted.")
        }
        guard let match = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ConnectorError.invalidArgument("No reminder found with that id.")
        }
        match.isCompleted = true
        match.completionDate = Date()
        try store.save(match, commit: true)
        return Self.info(match)
    }

    private static func info(_ reminder: EKReminder) -> ReminderInfo {
        var due: Date?
        if let comps = reminder.dueDateComponents {
            due = Calendar.current.date(from: comps)
        }
        return ReminderInfo(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "Untitled",
            notes: reminder.notes,
            due: due,
            isCompleted: reminder.isCompleted,
            listName: reminder.calendar?.title ?? "Reminders",
            priority: Int(reminder.priority)
        )
    }
}
#endif
