import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMKit
@testable import ConnectorKit

final class GmailConfigurationTests: XCTestCase {
    func testValidClientIDDerivesReversedRedirect() throws {
        let config = try XCTUnwrap(GmailConfiguration(clientID: "1234-abcd.apps.googleusercontent.com"))
        XCTAssertEqual(config.redirectScheme, "com.googleusercontent.apps.1234-abcd")
        XCTAssertEqual(config.redirectURI, "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
        XCTAssertEqual(config.oauth.callbackScheme, "com.googleusercontent.apps.1234-abcd")
        XCTAssertEqual(config.oauth.extraAuthorizationParameters["access_type"], "offline")
    }

    func testPlaceholderAndMalformedIDsAreRejected() {
        for bad in ["", "   ", "YOUR_CLIENT_ID", "$(GOOGLE_CLIENT_ID)", ".apps.googleusercontent.com", "abc.example.com"] {
            XCTAssertNil(GmailConfiguration(clientID: bad), bad)
        }
    }

    func testScopesAllowReadingAndDraftsOnly() {
        XCTAssertEqual(GmailConfiguration.scopes.count, 2)
        XCTAssertFalse(GmailConfiguration.scopes.contains { $0.hasSuffix("/mail.google.com/") || $0.hasSuffix("gmail.modify") })
    }
}

final class GmailTextTests: XCTestCase {
    private func part(_ mime: String, text: String? = nil, parts: [GmailClient.Part]? = nil) -> GmailClient.Part {
        GmailClient.Part(
            mimeType: mime, headers: nil,
            body: text.map { GmailClient.Body(data: Base64URL.encode($0)) }, parts: parts
        )
    }

    func testPrefersPlainTextInMultipart() {
        let tree = part("multipart/alternative", parts: [
            part("text/html", text: "<p>HTML <b>version</b></p>"),
            part("text/plain", text: "Plain version"),
        ])
        XCTAssertEqual(GmailText.bodyText(from: tree), "Plain version")
    }

    func testFallsBackToStrippedHTML() {
        let tree = part("multipart/alternative", parts: [
            part("text/html", text: "<style>p{color:red}</style><p>Hello &amp; welcome</p><div>Second&nbsp;line</div>"),
        ])
        let text = try! XCTUnwrap(GmailText.bodyText(from: tree))
        XCTAssertTrue(text.contains("Hello & welcome"))
        XCTAssertTrue(text.contains("Second line"))
        XCTAssertFalse(text.contains("color:red"))
        XCTAssertFalse(text.contains("<"))
    }

    func testNestedMultipartIsSearched() {
        let tree = part("multipart/mixed", parts: [
            part("multipart/related", parts: [part("text/plain", text: "Deep body")]),
            part("application/pdf"),
        ])
        XCTAssertEqual(GmailText.bodyText(from: tree), "Deep body")
    }

    func testQuotedRepliesAndBlankRunsAreRemoved() {
        let cleaned = GmailText.cleanup("Thanks!\r\n\r\n\r\n\r\nSee you.\n> older message\n> more")
        XCTAssertEqual(cleaned, "Thanks!\n\nSee you.")
    }

    func testVeryLongBodiesAreCapped() {
        let cleaned = GmailText.cleanup(String(repeating: "x", count: 10_000), maxCharacters: 100)
        XCTAssertEqual(cleaned.count, 101)
    }

    // MARK: Building drafts

    private func decodedDraft(_ raw: String) throws -> String {
        String(decoding: try XCTUnwrap(Base64URL.decode(raw)), as: UTF8.self)
    }

    func testRawMessageHasHeadersAndEncodedBody() throws {
        let raw = GmailText.rawMessage(to: "sam@example.com", subject: "Hello", body: "Line one\nLine two")
        let message = try decodedDraft(raw)
        XCTAssertTrue(message.contains("To: sam@example.com\r\n"))
        XCTAssertTrue(message.contains("Subject: Hello\r\n"))
        XCTAssertTrue(message.contains("Content-Type: text/plain; charset=\"UTF-8\""))
        let bodyPart = try XCTUnwrap(message.components(separatedBy: "\r\n\r\n").last)
        let body = try XCTUnwrap(Data(base64Encoded: bodyPart.replacingOccurrences(of: "\r\n", with: "")))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "Line one\nLine two")
    }

    func testNonASCIISubjectUsesEncodedWord() throws {
        let raw = GmailText.rawMessage(to: "a@b.com", subject: "Café ☕", body: "x")
        let message = try decodedDraft(raw)
        let line = try XCTUnwrap(message.components(separatedBy: "\r\n").first { $0.hasPrefix("Subject:") })
        XCTAssertTrue(line.hasPrefix("Subject: =?UTF-8?B?"))
        XCTAssertTrue(line.hasSuffix("?="))
    }

    func testHeaderInjectionIsNeutralised() throws {
        let raw = GmailText.rawMessage(to: "a@b.com", subject: "Hi\r\nBcc: attacker@evil.com", body: "x")
        let message = try decodedDraft(raw)
        XCTAssertFalse(message.contains("\r\nBcc:"), "a newline in the subject must not create a new header")
    }

    func testRecipientsAreValidated() throws {
        XCTAssertEqual(try GmailText.normalizeRecipients("sam@example.com"), "sam@example.com")
        XCTAssertEqual(try GmailText.normalizeRecipients("Sam Lee <sam@example.com>, kim@example.org"), "sam@example.com, kim@example.org")
        for bad in ["", "not-an-email", "a@b", "a@b.com\r\nBcc: x@y.com", "a b@c.com", "<>"] {
            XCTAssertThrowsError(try GmailText.normalizeRecipients(bad), bad)
        }
    }

    func testReplyHeadersChainReferences() throws {
        let raw = GmailText.rawMessage(to: "a@b.com", subject: "Re: x", body: "y", inReplyTo: "<2@x>", references: "<1@x>")
        let message = try decodedDraft(raw)
        XCTAssertTrue(message.contains("In-Reply-To: <2@x>"))
        XCTAssertTrue(message.contains("References: <1@x> <2@x>"))
    }
}

final class GmailConnectorTests: XCTestCase {
    private let calendar = utcCalendar()

    private func listJSON(_ ids: [String]) -> (Int, Any) {
        var body: [String: Any] = [:]
        if !ids.isEmpty {
            body["messages"] = ids.map { id -> [String: String] in ["id": id, "threadId": "t-\(id)"] }
        }
        return (200, body)
    }

    private func messageJSON(
        id: String, from: String = "Alice <alice@example.com>", subject: String = "Lunch?",
        snippet: String = "Are you free?", body: String? = nil, extraHeaders: [[String: String]] = []
    ) -> (Int, Any) {
        var headers: [[String: String]] = [
            ["name": "From", "value": from], ["name": "Subject", "value": subject], ["name": "To", "value": "me@example.com"],
        ]
        headers += extraHeaders
        var payload: [String: Any] = ["mimeType": "text/plain", "headers": headers]
        if let body { payload["body"] = ["data": Base64URL.encode(body)] }
        return (200, [
            "id": id, "threadId": "t-\(id)", "snippet": snippet,
            "internalDate": "1795000000000", "payload": payload,
        ])
    }

    private func client(_ http: MockHTTPClient, token: String = "tok") -> GmailClient {
        GmailClient(http: http, token: { token })
    }

    private func connector(http: MockHTTPClient, clientID: String? = "1234-abcd.apps.googleusercontent.com",
                           web: WebAuthenticator = ScriptedWeb(outcome: .approve(code: "c")),
                           store: TokenStore = InMemoryTokenStore()) -> GmailConnector {
        GmailConnector(
            configuration: clientID.flatMap(GmailConfiguration.init(clientID:)),
            http: http, store: store, web: web, calendar: calendar
        )
    }

    /// A connector that is already signed in, so tool tests can focus on the Gmail calls.
    private func signedInConnector(_ http: MockHTTPClient) async throws -> GmailConnector {
        let store = InMemoryTokenStore()
        let tokens = TokenSet(accessToken: "tok", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), account: "me@example.com")
        try store.save(try JSONEncoder().encode(tokens), for: "gmail")
        return connector(http: http, store: store)
    }

    private func tool(_ name: String, in connector: GmailConnector) throws -> ToolSpec {
        try XCTUnwrap(connector.tools().first { $0.name == name })
    }

    // MARK: Search / read

    func testSearchListsMessagesInRankedOrderWithBearerToken() async throws {
        let http = MockHTTPClient(json: [
            "/messages": listJSON(["m2", "m1"]),
            "/m1": messageJSON(id: "m1", subject: "First"),
            "/m2": messageJSON(id: "m2", subject: "Second"),
        ])
        let output = try await tool("gmail_search_emails", in: try await signedInConnector(http))
            .handler(ToolArguments(["query": "from:alice newer_than:7d", "limit": "2"]))

        let first = try XCTUnwrap(output.range(of: "Second"))
        let second = try XCTUnwrap(output.range(of: "First"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound, "Gmail's ranking order must be preserved")
        XCTAssertTrue(output.contains("id=m2"))
        XCTAssertTrue(output.contains("Alice <alice@example.com>"))

        let list = try XCTUnwrap(http.requests.first { $0.url!.path.hasSuffix("/messages") })
        XCTAssertEqual(list.queryDictionary["q"], "from:alice newer_than:7d")
        XCTAssertEqual(list.queryDictionary["maxResults"], "2")
        XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertTrue(http.requests.allSatisfy { $0.httpMethod != "POST" })
    }

    func testSearchWithNoResults() async throws {
        let http = MockHTTPClient(json: ["/messages": listJSON([])])
        let output = try await tool("gmail_search_emails", in: try await signedInConnector(http))
            .handler(ToolArguments(["query": "nothing here"]))
        XCTAssertTrue(output.contains("No emails matched"))
    }

    func testSearchClampsLimit() async throws {
        let http = MockHTTPClient(json: ["/messages": listJSON([])])
        _ = try await tool("gmail_search_emails", in: try await signedInConnector(http))
            .handler(ToolArguments(["query": "x", "limit": "500"]))
        let list = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(list.queryDictionary["maxResults"], String(GmailConnector.maxResults))
    }

    func testReadReturnsHeadersAndCleanBody() async throws {
        let http = MockHTTPClient(json: ["/m1": messageJSON(id: "m1", body: "Hi!\n\n> quoted\nSee you at noon.")])
        let output = try await tool("gmail_read_email", in: try await signedInConnector(http))
            .handler(ToolArguments(["message_id": "m1"]))
        XCTAssertTrue(output.contains("From: Alice <alice@example.com>"))
        XCTAssertTrue(output.contains("Subject: Lunch?"))
        XCTAssertTrue(output.contains("See you at noon."))
        XCTAssertFalse(output.contains("quoted"))
        XCTAssertEqual(http.requests.first?.queryDictionary["format"], "full")
    }

    func testReadRequiresAnId() async throws {
        let http = MockHTTPClient(json: [:])
        do {
            _ = try await tool("gmail_read_email", in: try await signedInConnector(http)).handler(ToolArguments())
            XCTFail("expected invalidArgument")
        } catch let error as ConnectorError {
            guard case .invalidArgument = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRejectedTokenAsksToReconnect() async throws {
        let http = MockHTTPClient(json: ["/messages": (401, ["error": ["message": "Invalid Credentials"]])])
        do {
            _ = try await tool("gmail_search_emails", in: try await signedInConnector(http))
                .handler(ToolArguments(["query": "x"]))
            XCTFail("expected notConnected")
        } catch let error as ConnectorError {
            guard case .notConnected(let message) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(message.contains("Reconnect"))
        }
    }

    func testGoogleErrorMessageIsSurfaced() async throws {
        let http = MockHTTPClient(json: ["/messages": (403, ["error": ["message": "Gmail API has not been used in project 123"]])])
        do {
            _ = try await tool("gmail_search_emails", in: try await signedInConnector(http))
                .handler(ToolArguments(["query": "x"]))
            XCTFail("expected http error")
        } catch let error as ConnectorError {
            XCTAssertTrue(error.localizedDescription.contains("Gmail API has not been used"))
        }
    }

    // MARK: Drafts

    func testDraftToolRequiresApprovalAndShowsFullText() throws {
        let http = MockHTTPClient(json: [:])
        let draft = try tool("gmail_create_draft", in: connector(http: http))
        XCTAssertTrue(draft.requiresApproval)
        let build = try XCTUnwrap(draft.approval)
        let request = build(ToolArguments(["to": "sam@example.com", "subject": "Hello", "body": "Dear Sam,\nThanks."]))
        XCTAssertEqual(request.confirmLabel, "Save draft")
        XCTAssertTrue(request.detail.contains("To: sam@example.com"))
        XCTAssertTrue(request.detail.contains("Subject: Hello"))
        XCTAssertTrue(request.detail.contains("Dear Sam,\nThanks."))
    }

    func testNoToolSendsMail() throws {
        let tools = try connector(http: MockHTTPClient(json: [:])).tools()
        XCTAssertEqual(Set(tools.map(\.name)), ["gmail_search_emails", "gmail_read_email", "gmail_create_draft"])
        XCTAssertFalse(tools.contains { $0.name.contains("send") })
        XCTAssertEqual(tools.filter(\.requiresApproval).map(\.name), ["gmail_create_draft"])
    }

    func testCreateDraftPostsAMessageToTheDraftsEndpointOnly() async throws {
        let http = MockHTTPClient(json: ["/drafts": (200, ["id": "d-1"])])
        let output = try await tool("gmail_create_draft", in: try await signedInConnector(http)).handler(
            ToolArguments(["to": "sam@example.com", "subject": "Hello", "body": "Hi Sam"])
        )
        XCTAssertTrue(output.contains("d-1"))
        XCTAssertTrue(output.contains("NOT been sent"))

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url!.path.hasSuffix("/drafts"))
        XCTAssertFalse(http.requests.contains { $0.url!.path.contains("send") })

        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        let message = try XCTUnwrap(body?["message"] as? [String: Any])
        let raw = try XCTUnwrap(message["raw"] as? String)
        let mime = String(decoding: try XCTUnwrap(Base64URL.decode(raw)), as: UTF8.self)
        XCTAssertTrue(mime.contains("To: sam@example.com"))
        XCTAssertTrue(mime.contains("Subject: Hello"))
        XCTAssertNil(message["threadId"])
    }

    func testReplyDraftKeepsThreadAndDefaultsRecipientAndSubject() async throws {
        let http = MockHTTPClient(json: [
            "/m1": messageJSON(id: "m1", from: "Alice <alice@example.com>", subject: "Lunch?", extraHeaders: [
                ["name": "Message-ID", "value": "<abc@mail.example.com>"],
                ["name": "Reply-To", "value": "alice.work@example.com"],
            ]),
            "/drafts": (200, ["id": "d-2"]),
        ])
        _ = try await tool("gmail_create_draft", in: try await signedInConnector(http)).handler(
            ToolArguments(["body": "Sounds good!", "reply_to_message_id": "m1"])
        )
        let post = try XCTUnwrap(http.requests.first { $0.httpMethod == "POST" })
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(post.httpBody)) as? [String: Any]
        let message = try XCTUnwrap(json?["message"] as? [String: Any])
        XCTAssertEqual(message["threadId"] as? String, "t-m1")
        let mime = String(decoding: try XCTUnwrap(Base64URL.decode(try XCTUnwrap(message["raw"] as? String))), as: UTF8.self)
        XCTAssertTrue(mime.contains("To: alice.work@example.com"), "Reply-To takes precedence")
        XCTAssertTrue(mime.contains("Subject: Re: Lunch?"))
        XCTAssertTrue(mime.contains("In-Reply-To: <abc@mail.example.com>"))
    }

    func testDraftValidationHappensBeforeAnyNetworkCall() async throws {
        let http = MockHTTPClient(json: [:])
        let spec = try tool("gmail_create_draft", in: try await signedInConnector(http))
        let bad: [[String: String]] = [
            ["to": "a@b.com", "subject": "s"],                                   // no body
            ["body": "x", "subject": "s"],                                       // no recipient
            ["body": "x", "to": "a@b.com"],                                      // no subject
            ["body": "x", "to": "not-an-address", "subject": "s"],               // bad recipient
        ]
        for input in bad {
            do {
                _ = try await spec.handler(ToolArguments(input))
                XCTFail("expected invalidArgument for \(input)")
            } catch let error as ConnectorError {
                guard case .invalidArgument = error else { return XCTFail("unexpected \(error)") }
            }
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testGuardKeepsDraftFromBeingSavedWithoutApproval() async throws {
        let http = MockHTTPClient(json: ["/drafts": (200, ["id": "d-3"])])
        let spec = try tool("gmail_create_draft", in: try await signedInConnector(http))
        let guarded = ToolGuard(approver: { _ in false }).wrap([spec])
        let output = try await guarded[0].handler(ToolArguments(["to": "a@b.com", "subject": "s", "body": "b"]))
        XCTAssertEqual(output, ToolGuard.declinedMessage)
        XCTAssertTrue(http.requests.isEmpty)
    }

    // MARK: Connect / disconnect

    func testUnconfiguredConnectorExplainsWhatIsMissing() async {
        let gmail = connector(http: MockHTTPClient(json: [:]), clientID: nil)
        guard case .unavailable(let why) = await gmail.status() else { return XCTFail("expected unavailable") }
        XCTAssertTrue(why.contains("GOOGLE_CLIENT_ID"))
        XCTAssertTrue(gmail.tools().isEmpty)
        do {
            try await gmail.connect()
            XCTFail("expected notConfigured")
        } catch let error as ConnectorError {
            guard case .notConfigured = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testConnectSignsInAndRecordsTheAccount() async throws {
        let http = MockHTTPClient(json: [
            "/token": (200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600]),
            "/profile": (200, ["emailAddress": "me@example.com"]),
        ])
        let gmail = connector(http: http)
        let before = await gmail.status()
        XCTAssertEqual(before, .notConnected)

        try await gmail.connect()
        let after = await gmail.status()
        XCTAssertEqual(after, .connected(account: "me@example.com"))
    }

    func testConnectFailsCleanlyWhenTheGmailAPIIsNotEnabled() async {
        let http = MockHTTPClient(json: [
            "/token": (200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600]),
            "/profile": (403, ["error": ["message": "Gmail API has not been used in project 1 before or it is disabled."]]),
            "/revoke": (200, [String: String]()),
        ])
        let gmail = connector(http: http)
        do {
            try await gmail.connect()
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Gmail API"))
        }
        let status = await gmail.status()
        XCTAssertEqual(status, .notConnected, "a half-connected account must not be left behind")
    }

    func testDisconnectRemovesTokens() async throws {
        let http = MockHTTPClient(json: [
            "/token": (200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600]),
            "/profile": (200, ["emailAddress": "me@example.com"]),
            "/revoke": (200, [String: String]()),
        ])
        let store = InMemoryTokenStore()
        let gmail = connector(http: http, store: store)
        try await gmail.connect()
        await gmail.disconnect()
        let status = await gmail.status()
        XCTAssertEqual(status, .notConnected)
        XCTAssertNil(try store.load("gmail"))
    }
}
