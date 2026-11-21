import Foundation
import LLMKit

/// Brave Search API settings. The key is a personal API key (free tier available at
/// https://brave.com/search/api/), injected at build time from `BRAVE_API_KEY`.
public struct WebSearchConfiguration: Sendable, Equatable {
    public let apiKey: String

    /// Returns nil for a missing key or an unexpanded build placeholder such as `$(BRAVE_API_KEY)`.
    public init?(apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        self.apiKey = trimmed
    }
}

/// Searches the web for current information (news, recent events, anything the model cannot know),
/// using the Brave Search API. Returns a few titles and snippets for the model to summarise.
///
/// Only the search query leaves the device, sent to Brave with the user's own API key.
public struct WebSearchConnector: Connector {
    public let id = "web_search"
    public let displayName = "Web search"
    public let summary = "Look things up on the web: news, recent events, facts."
    public let symbolName = "magnifyingglass"
    public let dataNote = "Sends only your search query to Brave Search (brave.com), using your own API key. Results are given to the on-device model. Nothing else leaves this iPhone."
    public let hasAccount = false
    public var usesNetwork: Bool { true }

    public static let maxResults = 5
    public static let defaultResults = 3
    static let searchURL = "https://api.search.brave.com/res/v1/web/search"
    static let service = "Brave Search"

    private let configuration: WebSearchConfiguration?
    private let http: HTTPClient

    public init(configuration: WebSearchConfiguration?, http: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.http = http
    }

    public func status() async -> ConnectorStatus {
        configuration == nil
            ? .unavailable("Add your Brave Search API key (BRAVE_API_KEY) to enable web search. See docs/connectors.md.")
            : .connected(account: nil)
    }

    public func connect() async throws {
        guard configuration != nil else {
            throw ConnectorError.notConfigured("Web search is not configured. Add BRAVE_API_KEY (see docs/connectors.md).")
        }
    }

    public func disconnect() async {}

    public func tools() -> [ToolSpec] {
        guard let configuration else { return [] }
        return [searchTool(configuration)]
    }

    // MARK: Tool

    private func searchTool(_ configuration: WebSearchConfiguration) -> ToolSpec {
        let http = self.http
        return ToolSpec(
            name: "web_search",
            description: "Search the web for current or recent information: news, events, results, releases, facts you are not sure about. Returns titles, sources and short snippets. Use short keyword queries.",
            parameters: [
                ToolParameter("query", "Search keywords, for example 'Fed interest rate decision'."),
                ToolParameter("recency", "Only results from the last 'day', 'week', 'month' or 'year'. Leave out for any time.", required: false),
                ToolParameter("limit", "Number of results, 1 to \(Self.maxResults). Defaults to \(Self.defaultResults).", kind: .integer, required: false),
            ],
            label: "Searching the web",
            handler: { arguments in
                guard let query = arguments.string("query") else {
                    throw ConnectorError.invalidArgument("A search query is required.")
                }
                let limit = min(max(arguments.integer("limit") ?? Self.defaultResults, 1), Self.maxResults)
                let results = try await Self.search(
                    query: String(query.prefix(300)), recency: arguments.string("recency"),
                    limit: limit, apiKey: configuration.apiKey, http: http
                )
                return Self.render(results, query: query)
            }
        )
    }

    // MARK: Search

    struct Hit: Equatable {
        var title: String
        var host: String
        var snippet: String
        var age: String?
    }

    private struct Response: Decodable {
        struct Web: Decodable {
            struct Item: Decodable {
                var title: String?
                var url: String?
                var description: String?
                var age: String?
            }
            var results: [Item]?
        }
        var web: Web?
    }

    static func freshness(_ recency: String?) -> String? {
        switch recency?.lowercased() {
        case "day", "today", "24h", "pd": return "pd"
        case "week", "7d", "pw": return "pw"
        case "month", "30d", "pm": return "pm"
        case "year", "py": return "py"
        default: return nil
        }
    }

    static func search(
        query: String, recency: String?, limit: Int, apiKey: String, http: HTTPClient
    ) async throws -> [Hit] {
        var parameters = ["q": query, "count": String(limit), "safesearch": "moderate", "text_decorations": "false"]
        if let freshness = freshness(recency) { parameters["freshness"] = freshness }
        let url = try LiveData.url(searchURL, parameters)
        let data: Data
        do {
            data = try await LiveData.fetch(http, url, headers: ["X-Subscription-Token": apiKey], service: service)
        } catch ConnectorError.http(let status, _) where status == 401 || status == 403 {
            throw ConnectorError.authenticationFailed(
                "Brave Search rejected the API key. Check BRAVE_API_KEY and rebuild (see docs/connectors.md)."
            )
        } catch ConnectorError.http(let status, _) where status == 429 {
            throw ConnectorError.unexpectedResponse("Web search has hit its rate limit. Try again in a moment.")
        }
        let response = try LiveData.decode(Response.self, from: data, service: service)
        return (response.web?.results ?? []).prefix(limit).compactMap { item in
            guard let title = item.title.map(LiveData.plainText), !title.isEmpty else { return nil }
            var host = item.url.flatMap { URL(string: $0)?.host } ?? "unknown source"
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return Hit(
                title: title, host: host,
                snippet: LiveData.plainText(item.description ?? ""),
                age: item.age.map(LiveData.plainText)
            )
        }
    }

    // MARK: Output

    static func render(_ results: [Hit], query: String) -> String {
        guard !results.isEmpty else { return "No web results for \"\(query)\"." }
        var lines = ["Web results for \"\(query)\" (Brave Search):"]
        for (index, result) in results.enumerated() {
            var heading = "\(index + 1). \(result.title) | \(result.host)"
            if let age = result.age, !age.isEmpty { heading += " | \(age)" }
            lines.append(heading)
            if !result.snippet.isEmpty {
                lines.append("   " + TokenEstimator.truncate(result.snippet, toTokens: 50))
            }
        }
        return lines.joined(separator: "\n")
    }
}
