#if canImport(EventKit)
import Foundation
import EventKit

/// `CalendarProvider` backed by the device calendar through EventKit.
///
/// Requires `NSCalendarsFullAccessUsageDescription` in Info.plist. Reading events needs *full*
/// access; the write-only level cannot read, so it is reported as not connected.
public final class EventKitCalendarProvider: CalendarProvider, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func permission() async -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .notDetermined, .writeOnly: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public func events(from start: Date, to end: Date, limit: Int) async throws -> [CalendarEventInfo] {
        guard await permission() == .authorized else {
            throw ConnectorError.permissionDenied("Calendar access has not been granted.")
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map(Self.info)
    }

    public func createEvent(title: String, start: Date, end: Date, location: String?) async throws -> CalendarEventInfo {
        guard await permission() == .authorized else {
            throw ConnectorError.permissionDenied("Calendar access has not been granted.")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw ConnectorError.unexpectedResponse("There is no calendar that can accept new events.")
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        try store.save(event, span: .thisEvent)
        return Self.info(event)
    }

    private static func info(_ event: EKEvent) -> CalendarEventInfo {
        CalendarEventInfo(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            calendarName: event.calendar?.title ?? "Calendar"
        )
    }
}
#endif
