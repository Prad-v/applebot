import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

// OAuth 2.0 authorization-code flow with PKCE (RFC 7636) for public clients: there is no client
// secret in the app. Tokens live in the Keychain, never in UserDefaults, SwiftData, or logs.

public struct OAuthConfig: Sendable, Equatable {
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var revocationEndpoint: URL?
    public var clientID: String
    /// Custom-scheme redirect, for example `com.googleusercontent.apps.123:/oauth2redirect`.
    public var redirectURI: String
    public var scopes: [String]
    public var extraAuthorizationParameters: [String: String]

    public init(
        authorizationEndpoint: URL, tokenEndpoint: URL, revocationEndpoint: URL? = nil,
        clientID: String, redirectURI: String, scopes: [String],
        extraAuthorizationParameters: [String: String] = [:]
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.extraAuthorizationParameters = extraAuthorizationParameters
    }

    public var callbackScheme: String { URL(string: redirectURI)?.scheme ?? "" }
}

public struct TokenSet: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?
    public var account: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String? = nil, account: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.account = account
    }
}

/// Secure storage for serialized tokens, keyed by connector id.
public protocol TokenStore: Sendable {
    func load(_ key: String) throws -> Data?
    func save(_ data: Data, for key: String) throws
    func delete(_ key: String) throws
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func load(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    public func save(_ data: Data, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = data
    }

    public func delete(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = nil
    }
}

/// Presents the provider's sign-in page and returns the redirect URL it ends on. The app
/// implements this with `ASWebAuthenticationSession`; tests script it.
public protocol WebAuthenticator: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// PKCE helpers (RFC 7636, S256).
public enum PKCE {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A high-entropy random string of unreserved characters (43...128 characters per the RFC).
    public static func randomString(length: Int = 64) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<max(43, min(128, length))).map { _ in alphabet.randomElement(using: &generator)! })
    }

    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(SHA256.hash(Array(verifier.utf8)))
    }
}

#if canImport(Security)
/// Keychain-backed `TokenStore`. Items are readable only while the device is unlocked and never
/// leave this device (no iCloud Keychain sync, no backup restore to another phone).
public struct KeychainTokenStore: TokenStore {
    public struct KeychainError: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? { "Keychain error \(status)." }
    }

    private let service: String

    public init(service: String = "dev.kekaflow.applebot.connectors") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func load(_ key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func save(_ data: Data, for key: String) throws {
        let deleteStatus = SecItemDelete(query(key) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError(status: deleteStatus)
        }
        var attributes = query(key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
#endif

/// Runs sign-in, keeps tokens fresh, and signs out for one provider account.
public actor OAuthSession {
    private let config: OAuthConfig
    private let http: HTTPClient
    private let store: TokenStore
    private let key: String
    private let clock: @Sendable () -> Date
    /// Refresh this long before the real expiry so a token never dies mid-request.
    private let expirySkew: TimeInterval = 60
    private var refreshTask: Task<TokenSet, Error>?

    public init(
        config: OAuthConfig, http: HTTPClient, store: TokenStore, key: String,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.http = http
        self.store = store
        self.key = key
        self.clock = clock
    }

    // MARK: State

    public var isSignedIn: Bool { (try? loadTokens()) != nil }
    public var account: String? { (try? loadTokens())?.account }

    public func setAccount(_ account: String) {
        guard var tokens = try? loadTokens() else { return }
        tokens.account = account
        try? saveTokens(tokens)
    }

    // MARK: Sign in

    /// Opens the provider's sign-in page and stores the resulting tokens.
    @discardableResult
    public func signIn(using web: WebAuthenticator) async throws -> TokenSet {
        let verifier = PKCE.randomString()
        let state = PKCE.randomString(length: 32)
        let url = try authorizationURL(verifier: verifier, state: state)

        let callback: URL
        do {
            callback = try await web.authenticate(url: url, callbackScheme: config.callbackScheme)
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw ConnectorError.cancelled
        }

        let code = try Self.authorizationCode(from: callback, expectedState: state)
        let response = try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier,
        ])
        let tokens = try makeTokens(from: response, previous: nil)
        try saveTokens(tokens)
        return tokens
    }

    func authorizationURL(verifier: String, state: String) throws -> URL {
        guard var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw ConnectorError.notConfigured("The sign-in address is invalid.")
        }
        var items: [String: String] = [
            "response_type": "code",
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "scope": config.scopes.joined(separator: " "),
            "code_challenge": PKCE.challenge(for: verifier),
            "code_challenge_method": "S256",
            "state": state,
        ]
        for (name, value) in config.extraAuthorizationParameters { items[name] = value }
        components.queryItems = items.keys.sorted().map { URLQueryItem(name: $0, value: items[$0]) }
        guard let url = components.url else {
            throw ConnectorError.notConfigured("The sign-in address is invalid.")
        }
        return url
    }

    static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        if let error = value("error") {
            if error == "access_denied" { throw ConnectorError.cancelled }
            throw ConnectorError.authenticationFailed("Sign-in failed: \(value("error_description") ?? error).")
        }
        // The state check defeats forged redirects (CSRF) into the app's callback.
        guard value("state") == expectedState else {
            throw ConnectorError.authenticationFailed("Sign-in could not be verified. Please try again.")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw ConnectorError.authenticationFailed("Sign-in did not return an authorization code.")
        }
        return code
    }

    // MARK: Tokens

    /// A valid access token, refreshing it first when it is about to expire.
    public func accessToken() async throws -> String {
        guard let tokens = try loadTokens() else {
            throw ConnectorError.notConnected("Connect your account in Settings > Connectors first.")
        }
        if tokens.expiresAt.timeIntervalSince(clock()) > expirySkew {
            return tokens.accessToken
        }
        return try await refresh(tokens).accessToken
    }

    private func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = tokens.refreshToken else {
            try? store.delete(key)
            throw ConnectorError.notConnected("Your session expired. Reconnect in Settings > Connectors.")
        }
        let task = Task { () throws -> TokenSet in
            do {
                let response = try await requestTokens([
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": config.clientID,
                ])
                let refreshed = try makeTokens(from: response, previous: tokens)
                try saveTokens(refreshed)
                return refreshed
            } catch ConnectorError.http(let status, let message) where status == 400 || status == 401 {
                // The grant was revoked or expired (Google test-mode apps expire after 7 days).
                try? store.delete(key)
                throw ConnectorError.notConnected(
                    "Your session expired (\(message)). Reconnect in Settings > Connectors."
                )
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Revokes the token at the provider (best effort) and deletes it locally.
    public func signOut() async {
        if let tokens = try? loadTokens(), let endpoint = config.revocationEndpoint {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = FormEncoding.encode(["token": tokens.refreshToken ?? tokens.accessToken])
            _ = try? await http.send(request)
        }
        try? store.delete(key)
    }

    // MARK: Plumbing

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
    }

    private func requestTokens(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode(fields)
        let data = try await http.sendChecked(request)
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw ConnectorError.unexpectedResponse("The sign-in service sent an unexpected response.")
        }
    }

    private func makeTokens(from response: TokenResponse, previous: TokenSet?) throws -> TokenSet {
        TokenSet(
            accessToken: response.access_token,
            // Refresh responses usually omit the refresh token; keep the one we have.
            refreshToken: response.refresh_token ?? previous?.refreshToken,
            expiresAt: clock().addingTimeInterval(response.expires_in ?? 3600),
            scope: response.scope ?? previous?.scope,
            account: previous?.account
        )
    }

    private func loadTokens() throws -> TokenSet? {
        guard let data = try store.load(key) else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    private func saveTokens(_ tokens: TokenSet) throws {
        try store.save(try JSONEncoder().encode(tokens), for: key)
    }
}
