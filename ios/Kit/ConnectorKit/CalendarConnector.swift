import Foundation
import LLMKit

public enum PermissionState: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public struct CalendarEventInfo: Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var calendarName: String

    public init(
        id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
        location: String? = nil, calendarName: String = "Calendar"
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.calendarName = calendarName
    }
}

/// Source of calendar data. `EventKitCalendarProvider` is the real one (Apple platforms only);
/// `InMemoryCalendarProvider` serves tests, previews and the UI-test launch mode.
public protocol CalendarProvider: Sendable {
    func permission() async -> PermissionState
    /// Prompts the user the first time. Returns whether full access is now granted.
    func requestAccess() async throws -> Bool
    func events(from start: Date, to end: Date, limit: Int) async throws -> [CalendarEventInfo]
    func createEvent(title: String, start: Date, end: Date, location: String?) async throws -> CalendarEventInfo
}

public actor InMemoryCalendarProvider: CalendarProvider {
    private var state: PermissionState
    private var stored: [CalendarEventInfo]
    private let grantOnRequest: Bool

    public init(permission: PermissionState = .authorized, events: [CalendarEventInfo] = [], grantOnRequest: Bool = true) {
        self.state = permission
        self.stored = events
        self.grantOnRequest = grantOnRequest
    }

    public func permission() -> PermissionState { state }

    public func requestAccess() -> Bool {
        if state == .notDetermined { state = grantOnRequest ? .authorized : .denied }
        return state == .authorized
    }

    public func events(from start: Date, to end: Date, limit: Int) throws -> [CalendarEventInfo] {
        guard state == .authorized else {
            throw ConnectorError.permissionDenied("Calendar access has not been granted.")
        }
        return Array(stored.filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start }.prefix(limit))
    }

    public func createEvent(title: String, start: Date, end: Date, location: String?) throws -> CalendarEventInfo {
        guard state == .authorized else {
            throw ConnectorError.permissionDenied("Calendar access has not been granted.")
        }
        let event = CalendarEventInfo(
            id: "mem-\(stored.count + 1)", title: title, start: start, end: end, location: location
        )
        stored.append(event)
        return event
    }

    /// Test helper: everything currently stored.
    public func allEvents() -> [CalendarEventInfo] { stored }
}

/// Reads the device calendar and, after the user approves each one, adds events.
public struct CalendarConnector: Connector {
    public let id = "calendar"
    public let displayName = "Calendar"
    public let summary = "See your schedule and add events, after your approval."
    public let symbolName = "calendar"
    public let dataNote = "Reads events on this iPhone only. Event details are given to the on-device model and never leave the device."
    public let hasAccount = false

    private let provider: CalendarProvider
    private let calendar: Calendar
    private let clock: @Sendable () -> Date

    public static let maxDays = 14
    public static let maxEvents = 15

    public init(
        provider: CalendarProvider,
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
        case .denied: return .unavailable("Calendar access was denied. Allow it in Settings > Applebot.")
        case .restricted: return .unavailable("Calendar access is restricted on this device.")
        }
    }

    public func connect() async throws {
        let granted = try await provider.requestAccess()
        guard granted else {
            throw ConnectorError.permissionDenied("Calendar access was not granted. Allow it in Settings > Applebot.")
        }
    }

    public func disconnect() async {}

    public func tools() -> [ToolSpec] {
        [listEventsTool, createEventTool]
    }

    // MARK: Tools

    private var listEventsTool: ToolSpec {
        let provider = self.provider, calendar = self.calendar, clock = self.clock
        return ToolSpec(
            name: "calendar_list_events",
            description: "List the user's calendar events for one or more days. Use for questions about schedule, availability or what is planned.",
            parameters: [
                ToolParameter("start_date", "First day, as YYYY-MM-DD (or 'today' / 'tomorrow'). Defaults to today.", required: false),
                ToolParameter("days", "How many days to include, 1 to \(Self.maxDays). Defaults to 1.", kind: .integer, required: false),
            ],
            label: "Checking your calendar",
            handler: { arguments in
                let now = clock()
                var first = calendar.startOfDay(for: now)
                if let raw = arguments.string("start_date") {
                    guard let parsed = DateInput.parse(raw, now: now, calendar: calendar) else {
                        throw ConnectorError.invalidArgument("start_date must look like 2026-11-21.")
                    }
                    first = calendar.startOfDay(for: parsed.date)
                }
                let days = min(max(arguments.integer("days") ?? 1, 1), Self.maxDays)
                guard let end = calendar.date(byAdding: .day, value: days, to: first) else {
                    throw ConnectorError.invalidArgument("Could not work out the date range.")
                }
                let events = try await provider.events(from: first, to: end, limit: Self.maxEvents)
                let range = DateInput.format(first, calendar: calendar, includeTime: false)
                guard !events.isEmpty else {
                    return "No events for \(range)\(days > 1 ? " and the next \(days - 1) day(s)" : "")."
                }
                let lines = events.map { Self.describe($0, calendar: calendar) }
                return "Events from \(range) for \(days) day(s):\n" + lines.joined(separator: "\n")
            }
        )
    }

    private var createEventTool: ToolSpec {
        let provider = self.provider, calendar = self.calendar, clock = self.clock
        return ToolSpec(
            name: "calendar_create_event",
            description: "Add an event to the user's calendar. The user must approve it first. Only use when the user asked to add or schedule something.",
            parameters: [
                ToolParameter("title", "Event title."),
                ToolParameter("start", "Start as YYYY-MM-DD HH:mm in the user's local time."),
                ToolParameter("duration_minutes", "Length in minutes. Defaults to 60.", kind: .integer, required: false),
                ToolParameter("location", "Where it takes place.", required: false),
            ],
            label: "Adding a calendar event",
            requiresApproval: true,
            approval: { arguments in
                let draft = try? Self.draft(from: arguments, now: clock(), calendar: calendar)
                let when = draft.map {
                    "\(DateInput.format($0.start, calendar: calendar)) – \(DateInput.formatTime($0.end, calendar: calendar))"
                } ?? "Unclear time"
                var detail = "\(arguments.string("title") ?? "Untitled")\n\(when)"
                if let location = arguments.string("location") { detail += "\n\(location)" }
                return ApprovalRequest(
                    toolName: "calendar_create_event", title: "Add this event to your calendar?",
                    detail: detail, confirmLabel: "Add event"
                )
            },
            handler: { arguments in
                let draft = try Self.draft(from: arguments, now: clock(), calendar: calendar)
                let created = try await provider.createEvent(
                    title: draft.title, start: draft.start, end: draft.end, location: draft.location
                )
                return "Added to the calendar: " + Self.describe(created, calendar: calendar)
            }
        )
    }

    // MARK: Helpers

    struct EventDraft: Equatable {
        var title: String
        var start: Date
        var end: Date
        var location: String?
    }

    static func draft(from arguments: ToolArguments, now: Date, calendar: Calendar) throws -> EventDraft {
        guard let title = arguments.string("title") else {
            throw ConnectorError.invalidArgument("An event needs a title.")
        }
        guard let rawStart = arguments.string("start"),
              let parsed = DateInput.parse(rawStart, now: now, calendar: calendar), parsed.hasTime else {
            throw ConnectorError.invalidArgument("The start time must include a time, like 2026-11-21 15:00.")
        }
        let minutes = min(max(arguments.integer("duration_minutes") ?? 60, 5), 24 * 60)
        return EventDraft(
            title: String(title.prefix(200)),
            start: parsed.date,
            end: parsed.date.addingTimeInterval(Double(minutes) * 60),
            location: arguments.string("location").map { String($0.prefix(200)) }
        )
    }

    static func describe(_ event: CalendarEventInfo, calendar: Calendar) -> String {
        var line: String
        if event.isAllDay {
            line = "- \(DateInput.format(event.start, calendar: calendar, includeTime: false)) all day | \(event.title)"
        } else {
            line = "- \(DateInput.format(event.start, calendar: calendar))-"
                + "\(DateInput.formatTime(event.end, calendar: calendar)) | \(event.title)"
        }
        if let location = event.location, !location.isEmpty { line += " | at \(location)" }
        return line
    }
}
