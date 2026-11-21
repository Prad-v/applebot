import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared plumbing for the connectors that look up live public data (weather, stock quotes, web
/// search). None of them has an account: each sends one small query to a public service.
enum LiveData {
    static let userAgent = "Mozilla/5.0 (compatible; Applebot/1.0; +https://github.com/kekaflow/applebot)"

    /// `base?k=v&...` with RFC 3986 escaping. `URLComponents` would leave `+` unescaped, which servers
    /// read as a space, so queries like "C++" would silently change.
    static func url(_ base: String, _ query: [String: String]) throws -> URL {
        let encoded = String(decoding: FormEncoding.encode(query), as: UTF8.self)
        guard let url = URL(string: query.isEmpty ? base : "\(base)?\(encoded)") else {
            throw ConnectorError.invalidArgument("Could not build the request.")
        }
        return url
    }

    /// GET returning the body for 2xx. Connectivity failures become a plain-language error.
    static func fetch(
        _ http: HTTPClient, _ url: URL, headers: [String: String] = [:], service: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            return try await http.sendChecked(request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ConnectorError.unexpectedResponse(
                "Couldn't reach \(service). Check the internet connection and try again."
            )
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, service: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ConnectorError.unexpectedResponse("\(service) sent a reply Applebot couldn't read.")
        }
    }

    /// Fixed-point text that never depends on the device locale, and never prints "-0".
    static func number(_ value: Double, decimals: Int = 0) -> String {
        let text = String(format: "%.\(decimals)f", value)
        return Double(text) == 0 ? String(format: "%.\(decimals)f", 0.0) : text
    }

    /// Removes markup and entities from a search snippet and collapses whitespace.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&nbsp;": " ",
        ]
        for (entity, replacement) in entities { text = text.replacingOccurrences(of: entity, with: replacement) }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
