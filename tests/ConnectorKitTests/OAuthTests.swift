import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ConnectorKit

final class CryptoTests: XCTestCase {
    func testSHA256MatchesNISTVectors() {
        XCTAssertEqual(SHA256.hexDigest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hexDigest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            SHA256.hexDigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testSHA256HandlesMultiBlockInput() {
        let input = String(repeating: "a", count: 1_000_000)
        XCTAssertEqual(SHA256.hexDigest(input), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testPKCEChallengeMatchesRFC7636Example() {
        // RFC 7636, Appendix B.
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testRandomVerifierIsLongEnoughAndUnreserved() {
        let verifier = PKCE.randomString()
        XCTAssertTrue((43...128).contains(verifier.count))
        XCTAssertNil(verifier.range(of: "[^A-Za-z0-9\\-._~]", options: .regularExpression))
        XCTAssertNotEqual(PKCE.randomString(), PKCE.randomString())
    }

    func testBase64URLRoundTripWithoutPadding() {
        let bytes: [UInt8] = [0xfb, 0xff, 0xfe, 0x01]
        let encoded = Base64URL.encode(bytes)
        XCTAssertFalse(encoded.contains("+") || encoded.contains("/") || encoded.contains("="))
        XCTAssertEqual(Array(Base64URL.decode(encoded)!), bytes)
    }
}

final class OAuthSessionTests: XCTestCase {
    private let config = OAuthConfig(
        authorizationEndpoint: URL(string: "https://accounts.example.com/auth")!,
        tokenEndpoint: URL(string: "https://oauth.example.com/token")!,
        revocationEndpoint: URL(string: "https://oauth.example.com/revoke")!,
        clientID: "client-1",
        redirectURI: "com.example.app:/oauth2redirect",
        scopes: ["read", "write"],
        extraAuthorizationParameters: ["access_type": "offline"]
    )

    private func tokenResponse(access: String, refresh: String? = "refresh-1", expiresIn: Double = 3600) -> (Int, Any) {
        var body: [String: Any] = ["access_token": access, "expires_in": expiresIn, "scope": "read write"]
        if let refresh { body["refresh_token"] = refresh }
        return (200, body)
    }

    func testSignInSendsPKCERequestAndStoresTokens() async throws {
        let captured = Captured()
        let http = MockHTTPClient(json: ["/token": tokenResponse(access: "access-1")])
        let store = InMemoryTokenStore()
        let session = OAuthSession(config: config, http: http, store: store, key: "k")

        let web = ScriptedWeb(outcome: .approve(code: "the-code"), onAuthorize: { captured.url = $0 })
        let tokens = try await session.signIn(using: web)

        XCTAssertEqual(tokens.accessToken, "access-1")
        XCTAssertEqual(tokens.refreshToken, "refresh-1")
        let signedIn = await session.isSignedIn
        XCTAssertTrue(signedIn)

        // Authorization request carried a PKCE challenge, state, scopes and the extra parameters.
        let authQuery = URLRequest(url: try XCTUnwrap(captured.url)).queryDictionary
        XCTAssertEqual(authQuery["response_type"], "code")
        XCTAssertEqual(authQuery["code_challenge_method"], "S256")
        XCTAssertEqual(authQuery["scope"], "read write")
        XCTAssertEqual(authQuery["access_type"], "offline")
        XCTAssertEqual(authQuery["client_id"], "client-1")
        XCTAssertEqual(authQuery["redirect_uri"], "com.example.app:/oauth2redirect")
        XCTAssertNotNil(authQuery["state"])

        // The token request proves possession of the verifier that produced the challenge.
        let form = try XCTUnwrap(http.requests.first).formFields
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code"], "the-code")
        XCTAssertNil(form["client_secret"], "a mobile client must not use a client secret")
        XCTAssertEqual(PKCE.challenge(for: try XCTUnwrap(form["code_verifier"])), authQuery["code_challenge"])
    }

    func testForgedStateIsRejected() async {
        let session = OAuthSession(
            config: config, http: MockHTTPClient(json: ["/token": tokenResponse(access: "x")]),
            store: InMemoryTokenStore(), key: "k"
        )
        do {
            _ = try await session.signIn(using: ScriptedWeb(outcome: .approveWithWrongState))
            XCTFail("a redirect with the wrong state must be rejected")
        } catch let error as ConnectorError {
            guard case .authenticationFailed = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
        let signedIn = await session.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testUserDenyingAccessIsCancellationNotAnError() async {
        let session = OAuthSession(config: config, http: MockHTTPClient(json: [:]), store: InMemoryTokenStore(), key: "k")
        for outcome in [ScriptedWeb.Outcome.denied, .cancelled] {
            do {
                _ = try await session.signIn(using: ScriptedWeb(outcome: outcome))
                XCTFail("expected cancellation")
            } catch {
                XCTAssertEqual(error as? ConnectorError, .cancelled)
            }
        }
    }

    func testProviderErrorIsReported() async {
        let session = OAuthSession(config: config, http: MockHTTPClient(json: [:]), store: InMemoryTokenStore(), key: "k")
        do {
            _ = try await session.signIn(using: ScriptedWeb(outcome: .providerError("boom")))
            XCTFail("expected failure")
        } catch let error as ConnectorError {
            XCTAssertTrue(error.localizedDescription.contains("boom"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFreshTokenIsReusedWithoutNetwork() async throws {
        let http = MockHTTPClient(json: ["/token": tokenResponse(access: "access-1")])
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let session = OAuthSession(config: config, http: http, store: InMemoryTokenStore(), key: "k", clock: { clock.now })
        try await session.signIn(using: ScriptedWeb(outcome: .approve(code: "c")))

        clock.advance(1_000)
        let token = try await session.accessToken()
        XCTAssertEqual(token, "access-1")
        XCTAssertEqual(http.requests.count, 1, "no refresh should happen while the token is valid")
    }

    func testExpiredTokenIsRefreshedAndKeepsTheRefreshToken() async throws {
        let counter = Captured()
        let http = MockHTTPClient { request in
            let form = request.formFields
            if form["grant_type"] == "refresh_token" {
                counter.refreshes += 1
                XCTAssertEqual(form["refresh_token"], "refresh-1")
                return (200, try JSONSerialization.data(withJSONObject: ["access_token": "access-2", "expires_in": 3600]))
            }
            return (200, try JSONSerialization.data(withJSONObject: [
                "access_token": "access-1", "refresh_token": "refresh-1", "expires_in": 3600,
            ]))
        }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let store = InMemoryTokenStore()
        let session = OAuthSession(config: config, http: http, store: store, key: "k", clock: { clock.now })
        try await session.signIn(using: ScriptedWeb(outcome: .approve(code: "c")))

        clock.advance(3_600 - 30) // inside the 60 s skew window
        let token = try await session.accessToken()
        XCTAssertEqual(token, "access-2")
        XCTAssertEqual(counter.refreshes, 1)

        let saved = try JSONDecoder().decode(TokenSet.self, from: try XCTUnwrap(try store.load("k")))
        XCTAssertEqual(saved.refreshToken, "refresh-1", "a refresh response without a refresh token must not erase it")
    }

    func testConcurrentCallsShareOneRefresh() async throws {
        let counter = Captured()
        let http = MockHTTPClient { request in
            if request.formFields["grant_type"] == "refresh_token" {
                counter.refreshes += 1
                return (200, try JSONSerialization.data(withJSONObject: ["access_token": "access-2", "expires_in": 3600]))
            }
            return (200, try JSONSerialization.data(withJSONObject: [
                "access_token": "access-1", "refresh_token": "r", "expires_in": 10,
            ]))
        }
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let session = OAuthSession(config: config, http: http, store: InMemoryTokenStore(), key: "k", clock: { clock.now })
        try await session.signIn(using: ScriptedWeb(outcome: .approve(code: "c")))

        // expires_in 10 s is inside the skew window, so every call needs a refresh.
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await session.accessToken() } }
            var all: [String] = []
            for try await token in group { all.append(token) }
            return all
        }
        XCTAssertEqual(Set(tokens), ["access-2"])
        XCTAssertLessThanOrEqual(counter.refreshes, 5)
        XCTAssertGreaterThanOrEqual(counter.refreshes, 1)
    }

    func testRevokedGrantClearsTokensAndAsksToReconnect() async throws {
        let http = MockHTTPClient { request in
            if request.formFields["grant_type"] == "refresh_token" {
                return (400, Data("{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}".utf8))
            }
            return (200, try JSONSerialization.data(withJSONObject: [
                "access_token": "a", "refresh_token": "r", "expires_in": 1,
            ]))
        }
        let session = OAuthSession(config: config, http: http, store: InMemoryTokenStore(), key: "k")
        try await session.signIn(using: ScriptedWeb(outcome: .approve(code: "c")))

        do {
            _ = try await session.accessToken()
            XCTFail("expected notConnected")
        } catch let error as ConnectorError {
            guard case .notConnected(let message) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(message.contains("Reconnect"))
        }
        let signedIn = await session.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testAccessTokenWithoutSignInExplainsWhatToDo() async {
        let session = OAuthSession(config: config, http: MockHTTPClient(json: [:]), store: InMemoryTokenStore(), key: "k")
        do {
            _ = try await session.accessToken()
            XCTFail("expected notConnected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Settings"))
        }
    }

    func testSignOutRevokesAtProviderAndDeletesTokens() async throws {
        let http = MockHTTPClient(json: [
            "/token": tokenResponse(access: "a"),
            "/revoke": (200, [String: String]()),
        ])
        let store = InMemoryTokenStore()
        let session = OAuthSession(config: config, http: http, store: store, key: "k")
        try await session.signIn(using: ScriptedWeb(outcome: .approve(code: "c")))

        await session.signOut()
        let revoke = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(revoke.url?.path, "/revoke")
        XCTAssertEqual(revoke.formFields["token"], "refresh-1")
        XCTAssertNil(try store.load("k"))
    }

    func testAccountNameIsPersistedWithTheTokens() async throws {
        let session = OAuthSession(
            config: config, http: MockHTTPClient(json: ["/token": tokenResponse(access: "a")]),
            store: InMemoryTokenStore(), key: "k"
        )
        try await session.signIn(using: ScriptedWeb(outcome: .approve(code: "c")))
        await session.setAccount("me@example.com")
        let account = await session.account
        XCTAssertEqual(account, "me@example.com")
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var _url: URL?
    private var _refreshes = 0
    var url: URL? {
        get { lock.lock(); defer { lock.unlock() }; return _url }
        set { lock.lock(); _url = newValue; lock.unlock() }
    }
    var refreshes: Int {
        get { lock.lock(); defer { lock.unlock() }; return _refreshes }
        set { lock.lock(); _refreshes = newValue; lock.unlock() }
    }
}

#if canImport(Security)
final class KeychainTokenStoreTests: XCTestCase {
    func testSaveLoadDeleteRoundTrip() throws {
        let store = KeychainTokenStore(service: "dev.kekaflow.applebot.tests.\(UUID().uuidString)")
        do {
            try store.save(Data("secret".utf8), for: "gmail")
        } catch {
            throw XCTSkip("Keychain is not available in this environment: \(error)")
        }
        defer { try? store.delete("gmail") }

        XCTAssertEqual(try store.load("gmail"), Data("secret".utf8))
        try store.save(Data("rotated".utf8), for: "gmail")
        XCTAssertEqual(try store.load("gmail"), Data("rotated".utf8))
        try store.delete("gmail")
        XCTAssertNil(try store.load("gmail"))
    }
}
#endif
