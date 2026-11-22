import XCTest
import LLMKit
@testable import ConnectorKit

final class RemindersConnectorTests: XCTestCase {
    private let calendar = utcCalendar()
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T10:30:00Z")!

    private func connector(
        permission: PermissionState = .authorized,
        reminders: [ReminderInfo] = []
    ) -> (RemindersConnector, InMemoryRemindersProvider) {
        let provider = InMemoryRemindersProvider(permission: permission, reminders: reminders)
        let now = self.now
        return (RemindersConnector(provider: provider, calendar: calendar, clock: { now }), provider)
    }

    private func tool(_ name: String, in connector: RemindersConnector) throws -> ToolSpec {
        try XCTUnwrap(connector.tools().first { $0.name == name })
    }

    private var sample: [ReminderInfo] {
        [
            ReminderInfo(id: "1", title: "Buy milk", due: ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!),
            ReminderInfo(id: "2", title: "Call Sam", due: ISO8601DateFormatter().date(from: "2026-11-20T09:00:00Z")!),
            ReminderInfo(id: "3", title: "Someday book", due: nil),
            ReminderInfo(id: "4", title: "Done already", due: nil, isCompleted: true),
        ]
    }

    func testStatusFollowsPermission() async {
        let (ok, _) = connector(permission: .authorized)
        let okStatus = await ok.status()
        XCTAssertTrue(okStatus.isConnected)
        let (denied, _) = connector(permission: .denied)
        guard case .unavailable(let why) = await denied.status() else { return XCTFail("expected unavailable") }
        XCTAssertTrue(why.contains("Settings"))
    }

    func testConnectRequestsAccess() async throws {
        let (reminders, _) = connector(permission: .notDetermined)
        try await reminders.connect()
        let status = await reminders.status()
        XCTAssertTrue(status.isConnected)
    }

    func testListTodayIncludesDueAndUndated() async throws {
        let (reminders, _) = connector(reminders: sample)
        let list = try tool("reminders_list", in: reminders)
        let result = try await list.handler(ToolArguments(["scope": "today"]))
        XCTAssertTrue(result.contains("Buy milk"))
        XCTAssertTrue(result.contains("Someday book"))
        XCTAssertFalse(result.contains("Done already"))
        XCTAssertFalse(result.contains("Call Sam")) // due later in the week
    }

    func testListWeekIncludesLaterDue() async throws {
        let (reminders, _) = connector(reminders: sample)
        let list = try tool("reminders_list", in: reminders)
        let result = try await list.handler(ToolArguments(["scope": "week"]))
        XCTAssertTrue(result.contains("Call Sam"))
    }

    func testCreateRequiresApprovalAndAdds() async throws {
        let (reminders, provider) = connector(reminders: [])
        let create = try tool("reminders_create", in: reminders)
        XCTAssertTrue(create.requiresApproval)
        let approval = create.approval?(ToolArguments(["title": "Ship docs", "due": "tomorrow"]))
        XCTAssertEqual(approval?.confirmLabel, "Add reminder")
        let result = try await create.handler(ToolArguments(["title": "Ship docs", "due": "tomorrow"]))
        XCTAssertTrue(result.contains("Ship docs"))
        let all = await provider.allReminders()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "Ship docs")
    }

    func testCompleteMarksDone() async throws {
        let (reminders, provider) = connector(reminders: sample)
        let complete = try tool("reminders_complete", in: reminders)
        XCTAssertTrue(complete.requiresApproval)
        let result = try await complete.handler(ToolArguments(["id": "1"]))
        XCTAssertTrue(result.contains("Completed"))
        let all = await provider.allReminders()
        XCTAssertTrue(all.first(where: { $0.id == "1" })?.isCompleted == true)
    }

    func testOpenRemindersForBrief() async {
        let (reminders, _) = connector(reminders: sample)
        let open = await reminders.openReminders(limit: 10)
        XCTAssertTrue(open.contains(where: { $0.title == "Buy milk" }))
        XCTAssertFalse(open.contains(where: { $0.isCompleted }))
    }

    func testToolsAreNamedConsistently() {
        let (reminders, _) = connector()
        let names = Set(reminders.tools().map(\.name))
        XCTAssertEqual(names, ["reminders_list", "reminders_create", "reminders_complete"])
    }
}
