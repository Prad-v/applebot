import XCTest
import LLMKit
@testable import ConnectorKit

final class DateInputTests: XCTestCase {
    private let calendar = utcCalendar()
    // Wednesday 2026-11-18 10:30 UTC
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T10:30:00Z")!

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    func testDayOnlyHasNoTime() {
        let parsed = DateInput.parse("2026-11-21", now: now, calendar: calendar)
        XCTAssertEqual(parsed?.date, date("2026-11-21T00:00:00Z"))
        XCTAssertEqual(parsed?.hasTime, false)
    }

    func testDateAndTimeVariants() {
        for text in ["2026-11-21 15:00", "2026-11-21T15:00", "2026-11-21T15:00:00", "  2026-11-21 15:00  "] {
            let parsed = DateInput.parse(text, now: now, calendar: calendar)
            XCTAssertEqual(parsed?.date, date("2026-11-21T15:00:00Z"), text)
            XCTAssertEqual(parsed?.hasTime, true, text)
        }
    }

    func testExplicitOffsetWinsOverLocalZone() {
        let parsed = DateInput.parse("2026-11-21T15:00:00+01:00", now: now, calendar: calendar)
        XCTAssertEqual(parsed?.date, date("2026-11-21T14:00:00Z"))
    }

    func testRelativeWords() {
        let startOfToday = calendar.startOfDay(for: now)
        XCTAssertEqual(DateInput.parse("today", now: now, calendar: calendar)?.date, startOfToday)
        XCTAssertEqual(
            DateInput.parse("Tomorrow", now: now, calendar: calendar)?.date,
            calendar.date(byAdding: .day, value: 1, to: startOfToday)
        )
        XCTAssertEqual(DateInput.parse("now", now: now, calendar: calendar)?.date, now)
    }

    func testLocalZoneIsUsedForNaiveStrings() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let parsed = DateInput.parse("2026-11-21 09:00", now: now, calendar: tokyo)
        XCTAssertEqual(parsed?.date, date("2026-11-21T00:00:00Z"))
    }

    func testGarbageAndInvalidDatesAreRejected() {
        for text in ["", "   ", "next friday-ish", "2026-13-40", "21/11/2026", "2026-02-30"] {
            XCTAssertNil(DateInput.parse(text, now: now, calendar: calendar), text)
        }
    }
}

final class CalendarConnectorTests: XCTestCase {
    private let calendar = utcCalendar()
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T10:30:00Z")!

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func connector(
        permission: PermissionState = .authorized, events: [CalendarEventInfo] = []
    ) -> (CalendarConnector, InMemoryCalendarProvider) {
        let provider = InMemoryCalendarProvider(permission: permission, events: events)
        let now = self.now
        return (CalendarConnector(provider: provider, calendar: calendar, clock: { now }), provider)
    }

    private func tool(_ name: String, in connector: CalendarConnector) throws -> ToolSpec {
        try XCTUnwrap(connector.tools().first { $0.name == name })
    }

    private let sample: [CalendarEventInfo] = [
        CalendarEventInfo(id: "1", title: "Standup", start: ISO8601DateFormatter().date(from: "2026-11-18T09:00:00Z")!,
                          end: ISO8601DateFormatter().date(from: "2026-11-18T09:15:00Z")!),
        CalendarEventInfo(id: "2", title: "Dentist", start: ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!,
                          end: ISO8601DateFormatter().date(from: "2026-11-18T16:00:00Z")!, location: "Main St"),
        CalendarEventInfo(id: "3", title: "Offsite", start: ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")!,
                          end: ISO8601DateFormatter().date(from: "2026-11-21T00:00:00Z")!, isAllDay: true),
    ]

    // MARK: Status

    func testStatusFollowsPermission() async {
        let cases: [(PermissionState, Bool)] = [(.authorized, true), (.notDetermined, false), (.denied, false), (.restricted, false)]
        for (permission, connected) in cases {
            let (calendarConnector, _) = connector(permission: permission)
            let status = await calendarConnector.status()
            XCTAssertEqual(status.isConnected, connected, "\(permission)")
        }
        let (denied, _) = connector(permission: .denied)
        guard case .unavailable(let why) = await denied.status() else { return XCTFail("denied should be unavailable") }
        XCTAssertTrue(why.contains("Settings"))
    }

    func testConnectRequestsAccess() async throws {
        let (calendarConnector, _) = connector(permission: .notDetermined)
        try await calendarConnector.connect()
        let connected = await calendarConnector.status().isConnected
        XCTAssertTrue(connected)
    }

    func testConnectThrowsWhenUserDenies() async {
        let provider = InMemoryCalendarProvider(permission: .notDetermined, grantOnRequest: false)
        let calendarConnector = CalendarConnector(provider: provider, calendar: calendar)
        do {
            try await calendarConnector.connect()
            XCTFail("expected permissionDenied")
        } catch let error as ConnectorError {
            guard case .permissionDenied = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Reading

    func testListEventsDefaultsToToday() async throws {
        let (calendarConnector, _) = connector(events: sample)
        let output = try await tool("calendar_list_events", in: calendarConnector).handler(ToolArguments())
        XCTAssertTrue(output.contains("Standup"))
        XCTAssertTrue(output.contains("Dentist"))
        XCTAssertTrue(output.contains("at Main St"))
        XCTAssertFalse(output.contains("Offsite"), "events on later days must not appear")
        XCTAssertTrue(output.contains("Wed 2026-11-18 09:00-09:15"))
    }

    func testListEventsAcrossDaysIncludesAllDayEvents() async throws {
        let (calendarConnector, _) = connector(events: sample)
        let output = try await tool("calendar_list_events", in: calendarConnector)
            .handler(ToolArguments(["start_date": "2026-11-18", "days": "4"]))
        XCTAssertTrue(output.contains("Offsite"))
        XCTAssertTrue(output.contains("all day"))
    }

    func testListEventsReportsEmptyRange() async throws {
        let (calendarConnector, _) = connector(events: sample)
        let output = try await tool("calendar_list_events", in: calendarConnector)
            .handler(ToolArguments(["start_date": "2026-12-25"]))
        XCTAssertTrue(output.hasPrefix("No events"))
    }

    func testListEventsClampsDaysAndRejectsBadDate() async throws {
        let (calendarConnector, _) = connector(events: sample)
        let spec = try tool("calendar_list_events", in: calendarConnector)
        let output = try await spec.handler(ToolArguments(["days": "9999"]))
        XCTAssertTrue(output.contains("14 day(s)"))
        do {
            _ = try await spec.handler(ToolArguments(["start_date": "someday"]))
            XCTFail("expected invalidArgument")
        } catch let error as ConnectorError {
            guard case .invalidArgument = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testReadingWithoutPermissionFails() async throws {
        let (calendarConnector, _) = connector(permission: .denied)
        do {
            _ = try await tool("calendar_list_events", in: calendarConnector).handler(ToolArguments())
            XCTFail("expected permissionDenied")
        } catch let error as ConnectorError {
            guard case .permissionDenied = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: Writing

    func testCreateEventRequiresApprovalAndShowsExactDetails() throws {
        let (calendarConnector, _) = connector()
        let spec = try tool("calendar_create_event", in: calendarConnector)
        XCTAssertTrue(spec.requiresApproval)
        XCTAssertFalse(try tool("calendar_list_events", in: calendarConnector).requiresApproval)

        let buildApproval = try XCTUnwrap(spec.approval)
        let request = buildApproval(
            ToolArguments(["title": "Lunch with Sam", "start": "2026-11-21 12:30", "duration_minutes": "45", "location": "Cafe"])
        )
        XCTAssertTrue(request.detail.contains("Lunch with Sam"))
        XCTAssertTrue(request.detail.contains("Sat 2026-11-21 12:30 – 13:15"))
        XCTAssertTrue(request.detail.contains("Cafe"))
    }

    func testCreateEventWritesToCalendarWithDefaultsAndClamps() async throws {
        let (calendarConnector, provider) = connector()
        let spec = try tool("calendar_create_event", in: calendarConnector)
        let output = try await spec.handler(ToolArguments(["title": "Lunch", "start": "2026-11-21 12:30"]))
        XCTAssertTrue(output.hasPrefix("Added to the calendar"))

        let created = await provider.allEvents()
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].start, at("2026-11-21T12:30:00Z"))
        XCTAssertEqual(created[0].end, at("2026-11-21T13:30:00Z"), "default length is 60 minutes")

        _ = try await spec.handler(ToolArguments(["title": "Marathon", "start": "2026-11-22 08:00", "duration_minutes": "99999"]))
        let all = await provider.allEvents()
        XCTAssertEqual(all[1].end.timeIntervalSince(all[1].start), 24 * 3600)
    }

    func testCreateEventValidatesInput() async throws {
        let (calendarConnector, provider) = connector()
        let spec = try tool("calendar_create_event", in: calendarConnector)
        let badInputs: [[String: String]] = [
            ["start": "2026-11-21 12:30"],                 // no title
            ["title": "x"],                                // no start
            ["title": "x", "start": "2026-11-21"],         // day only: needs a time
            ["title": "x", "start": "sometime"],           // unparseable
        ]
        for input in badInputs {
            do {
                _ = try await spec.handler(ToolArguments(input))
                XCTFail("expected invalidArgument for \(input)")
            } catch let error as ConnectorError {
                guard case .invalidArgument = error else { return XCTFail("unexpected \(error)") }
            }
        }
        let events = await provider.allEvents()
        XCTAssertTrue(events.isEmpty, "invalid requests must not create anything")
    }

    // MARK: Integration with the safety layer

    func testGuardPreventsCreationUntilApproved() async throws {
        let (calendarConnector, provider) = connector()
        let spec = try tool("calendar_create_event", in: calendarConnector)
        let arguments = ToolArguments(["title": "Lunch", "start": "2026-11-21 12:30"])

        let denied = ToolGuard(approver: { _ in false }).wrap([spec])
        _ = try await denied[0].handler(arguments)
        let afterDenied = await provider.allEvents()
        XCTAssertTrue(afterDenied.isEmpty)

        let approved = ToolGuard(approver: { _ in true }).wrap([spec])
        _ = try await approved[0].handler(arguments)
        let afterApproved = await provider.allEvents()
        XCTAssertEqual(afterApproved.count, 1)
    }
}
