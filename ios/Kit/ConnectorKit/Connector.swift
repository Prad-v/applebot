import Foundation
import LLMKit

/// Whether a connector can currently be used.
public enum ConnectorStatus: Sendable, Equatable {
    /// Needs the user to connect (sign in or grant permission).
    case notConnected
    case connected(account: String?)
    /// Cannot be used until something outside the user's control changes (missing configuration, restricted device).
    case unavailable(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Errors connectors raise. All have messages written for the end user.
public enum ConnectorError: Error, Sendable, Equatable {
    case notConfigured(String)
    case notConnected(String)
    case permissionDenied(String)
    case authenticationFailed(String)
    case cancelled
    case http(status: Int, message: String)
    case invalidArgument(String)
    case unexpectedResponse(String)
}

extension ConnectorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured(let message), .notConnected(let message), .permissionDenied(let message),
             .authenticationFailed(let message), .invalidArgument(let message), .unexpectedResponse(let message):
            return message
        case .cancelled:
            return "Sign-in was cancelled."
        case .http(let status, let message):
            return "The service returned an error (\(status)): \(message)"
        }
    }
}

/// An external service the assistant can use, such as Gmail or the device calendar.
///
/// A connector contributes `ToolSpec`s. It never talks to the model directly; the chat pipeline
/// wraps its tools with approval, output limits and a call cap.
public protocol Connector: Sendable {
    /// Stable identifier, also the prefix of its tool names (for example `gmail`).
    var id: String { get }
    var displayName: String { get }
    /// One line shown in Settings.
    var summary: String { get }
    /// SF Symbol name.
    var symbolName: String { get }
    /// Plain-language statement of where the data goes, shown in Settings.
    var dataNote: String { get }
    /// `true` for connectors with an account the user signs in to (and can sign out of); `false`
    /// for ones that use an on-device permission such as the calendar.
    var hasAccount: Bool { get }
    /// `true` when using the connector sends something off the device (an account request, or a
    /// city, ticker or search query). Settings uses it to say when the app touches the network.
    /// Defaults to `hasAccount`; keyless lookups such as weather override it.
    var usesNetwork: Bool { get }

    func status() async -> ConnectorStatus
    /// Sign in or request the permission. Throws `ConnectorError` on failure.
    func connect() async throws
    /// Forget credentials. For permission-based connectors this is a no-op (iOS owns the permission).
    func disconnect() async
    func tools() -> [ToolSpec]
}

extension Connector {
    public var usesNetwork: Bool { hasAccount }
}

/// Persists which connectors the user has switched on.
public protocol ConnectorPreferences: Sendable {
    func enabledIDs() -> Set<String>
    func setEnabledIDs(_ ids: Set<String>)
}

public final class InMemoryConnectorPreferences: ConnectorPreferences, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String>

    public init(enabled: Set<String> = []) { ids = enabled }

    public func enabledIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return ids
    }

    public func setEnabledIDs(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        self.ids = ids
    }
}

public final class UserDefaultsConnectorPreferences: ConnectorPreferences, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "enabledConnectors") {
        self.defaults = defaults
        self.key = key
    }

    public func enabledIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func setEnabledIDs(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: key)
    }
}

/// One row of the Connectors settings screen.
public struct ConnectorInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var summary: String
    public var symbolName: String
    public var dataNote: String
    public var hasAccount: Bool
    public var usesNetwork: Bool
    public var status: ConnectorStatus
    public var isEnabled: Bool

    /// True when the assistant may call this connector's tools right now.
    public var isActive: Bool { isEnabled && status.isConnected }
}

/// Owns the set of connectors and decides which tools the model is offered.
///
/// A connector's tools are offered only when it is **connected and switched on**, so a user can
/// pause a connector without signing out.
public actor ConnectorRegistry {
    public nonisolated let connectors: [any Connector]
    private let preferences: ConnectorPreferences

    public init(connectors: [any Connector], preferences: ConnectorPreferences = InMemoryConnectorPreferences()) {
        self.connectors = connectors
        self.preferences = preferences
    }

    public func isEnabled(_ id: String) -> Bool {
        preferences.enabledIDs().contains(id)
    }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        guard connectors.contains(where: { $0.id == id }) else { return }
        var ids = preferences.enabledIDs()
        if enabled { ids.insert(id) } else { ids.remove(id) }
        preferences.setEnabledIDs(ids)
    }

    public func snapshot() async -> [ConnectorInfo] {
        var rows: [ConnectorInfo] = []
        let enabled = preferences.enabledIDs()
        for connector in connectors {
            rows.append(ConnectorInfo(
                id: connector.id, displayName: connector.displayName, summary: connector.summary,
                symbolName: connector.symbolName, dataNote: connector.dataNote, hasAccount: connector.hasAccount,
                usesNetwork: connector.usesNetwork,
                status: await connector.status(), isEnabled: enabled.contains(connector.id)
            ))
        }
        return rows
    }

    /// Connects and switches the connector on.
    public func connect(_ id: String) async throws {
        guard let connector = connectors.first(where: { $0.id == id }) else { return }
        try await connector.connect()
        setEnabled(id, true)
    }

    /// Signs out and switches the connector off.
    public func disconnect(_ id: String) async {
        guard let connector = connectors.first(where: { $0.id == id }) else { return }
        await connector.disconnect()
        setEnabled(id, false)
    }

    /// Tools for every connector that is connected and switched on. Names are de-duplicated so a
    /// misbehaving connector cannot shadow another's tools.
    public func activeTools() async -> [ToolSpec] {
        let enabled = preferences.enabledIDs()
        var seen = Set<String>()
        var tools: [ToolSpec] = []
        for connector in connectors where enabled.contains(connector.id) {
            guard await connector.status().isConnected else { continue }
            for tool in connector.tools() where seen.insert(tool.name).inserted {
                tools.append(tool)
            }
        }
        return tools
    }
}
