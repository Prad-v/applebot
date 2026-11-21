import Foundation
import Observation
import ConnectorKit
import LLMKit

/// UI-facing state for the Connectors screen, backed by `ConnectorRegistry`.
@MainActor
@Observable
final class ConnectorsModel {
    private(set) var rows: [ConnectorInfo] = []
    /// The connector currently signing in or out.
    private(set) var busyID: String?
    var errorMessage: String?

    @ObservationIgnored let registry: ConnectorRegistry

    init(registry: ConnectorRegistry) {
        self.registry = registry
    }

    func refresh() async {
        rows = await registry.snapshot()
    }

    func connect(_ id: String) async {
        guard busyID == nil else { return }
        busyID = id
        errorMessage = nil
        defer { busyID = nil }
        do {
            try await registry.connect(id)
        } catch ConnectorError.cancelled {
            // The user closed the sign-in sheet: not an error.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await refresh()
    }

    func disconnect(_ id: String) async {
        guard busyID == nil else { return }
        busyID = id
        defer { busyID = nil }
        await registry.disconnect(id)
        await refresh()
    }

    func setEnabled(_ id: String, _ enabled: Bool) async {
        await registry.setEnabled(id, enabled)
        await refresh()
    }

    /// Signs out of every account connector (used by "Delete all data").
    func disconnectAll() async {
        for connector in registry.connectors where connector.hasAccount {
            await registry.disconnect(connector.id)
        }
        await refresh()
    }

    /// Tools for the connectors that are connected and switched on.
    func activeTools() async -> [ToolSpec] {
        await registry.activeTools()
    }

    /// Names of the active connectors, for the chat's "Connected to" hint.
    var activeNames: [String] {
        rows.filter(\.isActive).map(\.displayName)
    }
}
