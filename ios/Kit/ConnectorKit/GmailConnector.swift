import Foundation
import LLMKit

/// Google OAuth settings for the iOS client type. The client ID is public by design (there is no
/// client secret in a mobile app); PKCE protects the code exchange.
public struct GmailConfiguration: Sendable, Equatable {
    /// `gmail.readonly` lets the assistant search and read mail. `gmail.compose` lets it save
    /// drafts. Note that Google's compose scope technically also permits sending; the app simply
    /// has no tool that does, and `GmailClient` has no send method.
    public static let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.compose",
    ]

    static let clientIDSuffix = ".apps.googleusercontent.com"

    public let clientID: String

    /// Returns nil for a missing, placeholder, or malformed client ID.
    public init?(clientID: String) {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(Self.clientIDSuffix), trimmed.count > Self.clientIDSuffix.count else { return nil }
        self.clientID = trimmed
    }

    /// `com.googleusercontent.apps.<id>` (the reversed client ID Google requires for iOS clients).
    public var redirectScheme: String {
        "com.googleusercontent.apps." + String(clientID.dropLast(Self.clientIDSuffix.count))
    }

    public var redirectURI: String { redirectScheme + ":/oauth2redirect" }

    public var oauth: OAuthConfig {
        OAuthConfig(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            revocationEndpoint: URL(string: "https://oauth2.googleapis.com/revoke")!,
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: Self.scopes,
            // offline + consent so Google returns a refresh token and the user sees exactly what is requested.
            extraAuthorizationParameters: ["access_type": "offline", "prompt": "consent"]
        )
    }
}

/// Search and read Gmail, and save reply drafts after the user approves each one.
public struct GmailConnector: Connector {
    public let id = "gmail"
    public let displayName = "Gmail"
    public let summary = "Search and read your email, and save reply drafts after your approval."
    public let symbolName = "envelope"
    public let dataNote = "Talks directly from this iPhone to Google. Email text is given to the on-device model and is not sent anywhere else. Drafts are saved in Gmail, never sent."
    public let hasAccount = true

    public static let maxResults = 8
    public static let defaultResults = 5

    private let configuration: GmailConfiguration?
    private let session: OAuthSession?
    private let client: GmailClient?
    private let web: WebAuthenticator
    private let calendar: Calendar

    public init(
        configuration: GmailConfiguration?,
        http: HTTPClient = URLSessionHTTPClient(),
        store: TokenStore,
        web: WebAuthenticator,
        calendar: Calendar = .current
    ) {
        self.configuration = configuration
        self.web = web
        self.calendar = calendar
        if let configuration {
            let session = OAuthSession(config: configuration.oauth, http: http, store: store, key: "gmail")
            self.session = session
            self.client = GmailClient(http: http, token: { try await session.accessToken() })
        } else {
            self.session = nil
            self.client = nil
        }
    }

    public func status() async -> ConnectorStatus {
        guard let session else {
            return .unavailable("Add your Google OAuth client ID (GOOGLE_CLIENT_ID) to enable Gmail. See docs/connectors.md.")
        }
        guard await session.isSignedIn else { return .notConnected }
        return .connected(account: await session.account)
    }

    public func connect() async throws {
        guard let session, let client else {
            throw ConnectorError.notConfigured("Gmail is not configured. Add GOOGLE_CLIENT_ID (see docs/connectors.md).")
        }
        try await session.signIn(using: web)
        do {
            // Proves the Gmail API is reachable (and enabled for the project) and shows which account connected.
            await session.setAccount(try await client.profile())
        } catch {
            await session.signOut()
            throw error
        }
    }

    public func disconnect() async {
        await session?.signOut()
    }

    public func tools() -> [ToolSpec] {
        guard let client else { return [] }
        return [searchTool(client), readTool(client), draftTool(client)]
    }

    // MARK: Tools

    private func searchTool(_ client: GmailClient) -> ToolSpec {
        let calendar = self.calendar
        return ToolSpec(
            name: "gmail_search_emails",
            description: "Search the user's Gmail. The query uses Gmail search syntax, for example 'from:alice newer_than:7d', 'subject:invoice is:unread', or plain keywords. Returns message ids to use with gmail_read_email.",
            parameters: [
                ToolParameter("query", "Gmail search query."),
                ToolParameter("limit", "Number of results, 1 to \(Self.maxResults). Defaults to \(Self.defaultResults).", kind: .integer, required: false),
            ],
            label: "Searching Gmail",
            handler: { arguments in
                let query = arguments.string("query") ?? ""
                let limit = min(max(arguments.integer("limit") ?? Self.defaultResults, 1), Self.maxResults)
                let results = try await client.search(query: query, limit: limit)
                guard !results.isEmpty else { return "No emails matched \"\(query)\"." }
                return results.enumerated().map { index, message in
                    let when = message.date.map { DateInput.format($0, calendar: calendar) } ?? "unknown date"
                    let snippet = TokenEstimator.truncate(message.snippet, toTokens: 40)
                    return "\(index + 1). id=\(message.id) | \(when) | From: \(message.from) | Subject: \(message.subject)\n   \(snippet)"
                }.joined(separator: "\n")
            }
        )
    }

    private func readTool(_ client: GmailClient) -> ToolSpec {
        let calendar = self.calendar
        return ToolSpec(
            name: "gmail_read_email",
            description: "Read one email by its message id (from gmail_search_emails). Returns the sender, subject, date and text.",
            parameters: [ToolParameter("message_id", "Message id from a search result.")],
            label: "Reading an email",
            handler: { arguments in
                guard let id = arguments.string("message_id") else {
                    throw ConnectorError.invalidArgument("message_id is required.")
                }
                let message = try await client.read(id: id)
                let when = message.summary.date.map { DateInput.format($0, calendar: calendar) } ?? "unknown date"
                return """
                From: \(message.summary.from)
                To: \(message.to)
                Date: \(when)
                Subject: \(message.summary.subject)
                Message id: \(message.summary.id)

                \(message.body)
                """
            }
        )
    }

    private func draftTool(_ client: GmailClient) -> ToolSpec {
        ToolSpec(
            name: "gmail_create_draft",
            description: "Save an email draft in Gmail. It is NOT sent; the user reviews and sends it themselves. The user must approve the text first. To reply, pass reply_to_message_id and you can omit to and subject.",
            parameters: [
                ToolParameter("body", "The full text of the email."),
                ToolParameter("to", "Recipient email address. Optional when replying.", required: false),
                ToolParameter("subject", "Subject line. Optional when replying.", required: false),
                ToolParameter("reply_to_message_id", "Message id to reply to (keeps the thread).", required: false),
            ],
            label: "Saving a Gmail draft",
            requiresApproval: true,
            approval: { arguments in
                var lines: [String] = []
                if let to = arguments.string("to") { lines.append("To: \(to)") }
                else if arguments.string("reply_to_message_id") != nil { lines.append("To: (the sender of the original email)") }
                if let subject = arguments.string("subject") { lines.append("Subject: \(subject)") }
                lines.append("")
                lines.append(arguments.string("body") ?? "")
                return ApprovalRequest(
                    toolName: "gmail_create_draft", title: "Save this draft in Gmail?",
                    detail: lines.joined(separator: "\n"), confirmLabel: "Save draft"
                )
            },
            handler: { arguments in
                guard let body = arguments.string("body") else {
                    throw ConnectorError.invalidArgument("A draft needs body text.")
                }
                var recipients = arguments.string("to")
                var subject = arguments.string("subject")
                var inReplyTo: String?
                var references: String?
                var threadID: String?

                if let replyID = arguments.string("reply_to_message_id") {
                    let original = try await client.metadata(id: replyID)
                    threadID = original.summary.threadID
                    inReplyTo = original.messageIDHeader
                    references = original.references
                    if recipients == nil {
                        recipients = original.replyTo.isEmpty ? original.summary.from : original.replyTo
                    }
                    if subject == nil {
                        let base = original.summary.subject
                        subject = base.lowercased().hasPrefix("re:") ? base : "Re: \(base)"
                    }
                }
                guard let recipients else { throw ConnectorError.invalidArgument("A draft needs a recipient (to).") }
                guard let subject else { throw ConnectorError.invalidArgument("A draft needs a subject.") }

                let raw = GmailText.rawMessage(
                    to: try GmailText.normalizeRecipients(recipients), subject: subject, body: body,
                    inReplyTo: inReplyTo, references: references
                )
                let draftID = try await client.createDraft(rawMessage: raw, threadID: threadID)
                return "Draft saved in Gmail (id \(draftID)). It has NOT been sent; the user can review and send it from the Gmail app."
            }
        )
    }
}
