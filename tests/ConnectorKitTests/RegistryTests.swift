import XCTest
import LLMKit
@testable import ConnectorKit

private struct FakeConnector: Connector {
    let id: String
    var displayName: String { id.capitalized }
    let summary = "fake"
    let symbolName = "star"
    let dataNote = "none"
    let hasAccount = true
    let state: ConnectorStatus
    var toolNames: [String] = []
    var connectError: ConnectorError?

    func status() async -> ConnectorStatus { state }
    func connect() async throws { if let connectError { throw connectError } }
    func disconnect() async {}
    func tools() -> [ToolSpec] {
        toolNames.map { name in ToolSpec(name: name, description: name) { _ in name } }
    }
}

final class ConnectorRegistryTests: XCTestCase {
    func testOnlyEnabledAndConnectedConnectorsContributeTools() async {
        let registry = ConnectorRegistry(connectors: [
            FakeConnector(id: "a", state: .connected(account: nil), toolNames: ["a_one", "a_two"]),
            FakeConnector(id: "b", state: .connected(account: nil), toolNames: ["b_one"]),
            FakeConnector(id: "c", state: .notConnected, toolNames: ["c_one"]),
            FakeConnector(id: "d", state: .unavailable("nope"), toolNames: ["d_one"]),
        ])
        await registry.setEnabled("a", true)
        await registry.setEnabled("c", true)
        await registry.setEnabled("d", true)
        // "b" is connected but switched off.

        let names = await registry.activeTools().map(\.name)
        XCTAssertEqual(names, ["a_one", "a_two"])
    }

    func testNothingIsEnabledByDefault() async {
        let registry = ConnectorRegistry(connectors: [FakeConnector(id: "a", state: .connected(account: nil), toolNames: ["x"])])
        let tools = await registry.activeTools()
        XCTAssertTrue(tools.isEmpty, "connectors must be opt-in")
    }

    func testDuplicateToolNamesAreDroppedSoOneConnectorCannotShadowAnother() async {
        let registry = ConnectorRegistry(connectors: [
            FakeConnector(id: "a", state: .connected(account: nil), toolNames: ["shared"]),
            FakeConnector(id: "b", state: .connected(account: nil), toolNames: ["shared", "b_only"]),
        ])
        await registry.setEnabled("a", true)
        await registry.setEnabled("b", true)
        let names = await registry.activeTools().map(\.name)
        XCTAssertEqual(names, ["shared", "b_only"])
    }

    func testConnectEnablesAndDisconnectDisables() async throws {
        let registry = ConnectorRegistry(connectors: [FakeConnector(id: "a", state: .connected(account: "me"))])
        try await registry.connect("a")
        var enabled = await registry.isEnabled("a")
        XCTAssertTrue(enabled)
        await registry.disconnect("a")
        enabled = await registry.isEnabled("a")
        XCTAssertFalse(enabled)
    }

    func testFailedConnectDoesNotEnable() async {
        let registry = ConnectorRegistry(connectors: [
            FakeConnector(id: "a", state: .notConnected, connectError: .cancelled),
        ])
        do {
            try await registry.connect("a")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ConnectorError, .cancelled)
        }
        let enabled = await registry.isEnabled("a")
        XCTAssertFalse(enabled)
    }

    func testUnknownIDsAreIgnored() async throws {
        let preferences = InMemoryConnectorPreferences()
        let registry = ConnectorRegistry(connectors: [FakeConnector(id: "a", state: .notConnected)], preferences: preferences)
        await registry.setEnabled("ghost", true)
        try await registry.connect("ghost")
        XCTAssertTrue(preferences.enabledIDs().isEmpty)
    }

    func testSnapshotReportsStatusAndEnabledFlag() async {
        let registry = ConnectorRegistry(connectors: [
            FakeConnector(id: "a", state: .connected(account: "me@x.com")),
            FakeConnector(id: "b", state: .notConnected),
        ])
        await registry.setEnabled("a", true)
        let rows = await registry.snapshot()
        XCTAssertEqual(rows.map(\.id), ["a", "b"])
        XCTAssertEqual(rows[0].status, .connected(account: "me@x.com"))
        XCTAssertTrue(rows[0].isActive)
        XCTAssertFalse(rows[1].isActive)
    }

    func testPreferencesPersistAcrossRegistries() async {
        let preferences = InMemoryConnectorPreferences()
        let first = ConnectorRegistry(connectors: [FakeConnector(id: "a", state: .connected(account: nil), toolNames: ["x"])], preferences: preferences)
        await first.setEnabled("a", true)
        let second = ConnectorRegistry(connectors: [FakeConnector(id: "a", state: .connected(account: nil), toolNames: ["x"])], preferences: preferences)
        let tools = await second.activeTools()
        XCTAssertEqual(tools.map(\.name), ["x"])
    }

    func testUserDefaultsPreferencesRoundTrip() {
        let suite = "applebot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsConnectorPreferences(defaults: defaults)
        XCTAssertTrue(preferences.enabledIDs().isEmpty)
        preferences.setEnabledIDs(["gmail", "calendar"])
        XCTAssertEqual(preferences.enabledIDs(), ["gmail", "calendar"])
    }
}
