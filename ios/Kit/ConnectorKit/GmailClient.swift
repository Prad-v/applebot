import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GmailMessageSummary: Sendable, Equatable {
    public var id: String
    public var threadID: String
    public var from: String
    public var subject: String
    public var date: Date?
    public var snippet: String
}

public struct GmailMessage: Sendable, Equatable {
    public var summary: GmailMessageSummary
    public var to: String
    public var replyTo: String
    public var messageIDHeader: String
    public var references: String
    public var body: String
}

/// Thin Gmail REST client. It only implements what the assistant needs, and deliberately has
/// **no send operation**: the most the assistant can do is save a draft.
public struct GmailClient: Sendable {
    public typealias TokenProvider = @Sendable () async throws -> String

    private let http: HTTPClient
    private let token: TokenProvider
    private let baseURL: URL

    public init(
        http: HTTPClient, token: @escaping TokenProvider,
        baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    ) {
        self.http = http
        self.token = token
        self.baseURL = baseURL
    }

    // MARK: Wire types

    private struct ProfileResponse: Decodable { let emailAddress: String }

    private struct ListResponse: Decodable {
        struct Reference: Decodable { let id: String }
        let messages: [Reference]?
    }

    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { let data: String? }
    struct Part: Decodable {
        let mimeType: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?
    }
    private struct RawMessage: Decodable {
        let id: String
        let threadId: String?
        let snippet: String?
        let internalDate: String?
        let payload: Part?
    }
    private struct DraftResponse: Decodable { let id: String }

    // MARK: Operations

    public func profile() async throws -> String {
        let data = try await get("profile", query: [])
        return try decode(ProfileResponse.self, from: data).emailAddress
    }

    public func search(query: String, limit: Int) async throws -> [GmailMessageSummary] {
        var items = [URLQueryItem(name: "maxResults", value: String(limit))]
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        let list = try decode(ListResponse.self, from: try await get("messages", query: items))
        let ids = (list.messages ?? []).map(\.id)
        guard !ids.isEmpty else { return [] }

        // Fetch metadata concurrently but return in the order Gmail ranked them.
        var byID: [String: GmailMessageSummary] = [:]
        try await withThrowingTaskGroup(of: GmailMessageSummary.self) { group in
            for id in ids {
                group.addTask { try await self.metadata(id: id).summary }
            }
            for try await summary in group { byID[summary.id] = summary }
        }
        return ids.compactMap { byID[$0] }
    }

    /// Message headers only (no body).
    func metadata(id: String) async throws -> GmailMessage {
        let headers = ["From", "To", "Reply-To", "Subject", "Date", "Message-ID", "References"]
        let items = [URLQueryItem(name: "format", value: "metadata")]
            + headers.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        let raw = try decode(RawMessage.self, from: try await get("messages/\(Self.encodePath(id))", query: items))
        return Self.makeMessage(raw, body: "")
    }

    public func read(id: String) async throws -> GmailMessage {
        let raw = try decode(
            RawMessage.self,
            from: try await get("messages/\(Self.encodePath(id))", query: [URLQueryItem(name: "format", value: "full")])
        )
        let body = raw.payload.flatMap(GmailText.bodyText(from:)) ?? raw.snippet ?? ""
        return Self.makeMessage(raw, body: body)
    }

    /// Saves a draft (never sends). Returns the draft id.
    public func createDraft(rawMessage: String, threadID: String?) async throws -> String {
        var message: [String: Any] = ["raw": rawMessage]
        if let threadID { message["threadId"] = threadID }
        let payload = try JSONSerialization.data(withJSONObject: ["message": message])

        var request = try await authorized(path: "drafts", query: [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        return try decode(DraftResponse.self, from: try await perform(request)).id
    }

    // MARK: Plumbing

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        try await perform(try await authorized(path: path, query: query))
    }

    private func authorized(path: String, query: [URLQueryItem]) async throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else {
            throw ConnectorError.unexpectedResponse("Could not build the Gmail request.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw ConnectorError.unexpectedResponse("Could not build the Gmail request.")
        }
        var request = URLRequest(url: url)
        let bearer = try await token()
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            return try await http.sendChecked(request)
        } catch ConnectorError.http(let status, _) where status == 401 {
            throw ConnectorError.notConnected("Gmail rejected the saved sign-in. Reconnect in Settings > Connectors.")
        } catch ConnectorError.http(let status, _) where status == 429 {
            throw ConnectorError.http(status: 429, message: "Gmail is rate limiting requests. Try again in a minute.")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ConnectorError.unexpectedResponse("Gmail sent a response the app could not read.")
        }
    }

    static func encodePath(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }

    private static func makeMessage(_ raw: RawMessage, body: String) -> GmailMessage {
        let headers = raw.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let date = raw.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        let summary = GmailMessageSummary(
            id: raw.id, threadID: raw.threadId ?? raw.id, from: header("From"),
            subject: header("Subject"), date: date, snippet: raw.snippet ?? ""
        )
        return GmailMessage(
            summary: summary, to: header("To"), replyTo: header("Reply-To"),
            messageIDHeader: header("Message-ID"), references: header("References"), body: body
        )
    }
}

/// Email text extraction and RFC 5322 message building.
enum GmailText {
    /// Prefers the text/plain part, falling back to tag-stripped HTML.
    static func bodyText(from part: GmailClient.Part) -> String? {
        if let plain = find("text/plain", in: part), !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanup(plain)
        }
        if let html = find("text/html", in: part) { return cleanup(stripHTML(html)) }
        return nil
    }

    private static func find(_ mime: String, in part: GmailClient.Part) -> String? {
        if part.mimeType?.lowercased() == mime, let data = part.body?.data, let decoded = Base64URL.decode(data) {
            return String(decoding: decoded, as: UTF8.self)
        }
        for child in part.parts ?? [] {
            if let found = find(mime, in: child) { return found }
        }
        return nil
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        let rules: [(String, String)] = [
            ("(?is)<(script|style)[^>]*>.*?</\\1>", " "),
            ("(?i)<br\\s*/?>|</p>|</div>|</tr>|</li>", "\n"),
            ("<[^>]+>", " "),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text
    }

    /// Removes quoted replies, trailing spaces and runs of blank lines so more of the message fits.
    static func cleanup(_ text: String, maxCharacters: Int = 4000) -> String {
        var lines: [String] = []
        var blank = 0
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { continue }
            if line.isEmpty {
                blank += 1
                if blank > 1 { continue }
            } else {
                blank = 0
            }
            lines.append(line)
        }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.count > maxCharacters ? String(joined.prefix(maxCharacters)) + "…" : joined
    }

    // MARK: Building a draft

    /// Strips CR/LF so user- or model-supplied text can never inject extra headers.
    static func headerValue(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Accepts `a@b.com`, `Name <a@b.com>`, and comma-separated lists. Throws on anything else.
    static func normalizeRecipients(_ text: String) throws -> String {
        let pieces = text.split(whereSeparator: { $0 == "," || $0 == ";" })
        var addresses: [String] = []
        for piece in pieces {
            var candidate = piece.trimmingCharacters(in: .whitespaces)
            if let open = candidate.lastIndex(of: "<"), let close = candidate.lastIndex(of: ">"), open < close {
                candidate = String(candidate[candidate.index(after: open)..<close])
            }
            let valid = candidate.range(
                of: "^[A-Za-z0-9._%+'-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression
            ) != nil
            guard valid else {
                throw ConnectorError.invalidArgument("\"\(headerValue(String(piece)))\" is not a valid email address.")
            }
            addresses.append(candidate)
        }
        guard !addresses.isEmpty else { throw ConnectorError.invalidArgument("A draft needs a recipient.") }
        return addresses.joined(separator: ", ")
    }

    /// RFC 2047 encoded-word for non-ASCII subjects.
    static func encodeSubject(_ subject: String) -> String {
        let clean = headerValue(subject)
        if clean.allSatisfy({ $0.isASCII }) { return clean }
        return "=?UTF-8?B?\(Data(clean.utf8).base64EncodedString())?="
    }

    static func rawMessage(
        to: String, subject: String, body: String, inReplyTo: String? = nil, references: String? = nil
    ) -> String {
        var headers = ["To: \(to)", "Subject: \(encodeSubject(subject))"]
        if let inReplyTo, !inReplyTo.isEmpty {
            headers.append("In-Reply-To: \(headerValue(inReplyTo))")
            let chain = [references, inReplyTo].compactMap { $0 }.filter { !$0.isEmpty }.map(headerValue).joined(separator: " ")
            headers.append("References: \(chain)")
        }
        headers += [
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: base64",
        ]
        let encodedBody = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + encodedBody
        return Base64URL.encode(message)
    }
}
