import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP seam so connectors can be tested without a network.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    /// Ephemeral session: no cookies or cache are written to disk, since responses contain personal data.
    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.unexpectedResponse("The server sent an unreadable response.")
        }
        return (data, http)
    }
}

extension HTTPClient {
    /// Sends the request and returns the body for 2xx, throwing `ConnectorError.http` otherwise.
    func sendChecked(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.http(status: response.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    /// Pulls a short message out of Google-style (`{"error":{"message":..}}`) or OAuth-style
    /// (`{"error":"invalid_grant","error_description":..}`) error bodies.
    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let description = object["error_description"] as? String { return description }
            if let error = object["error"] as? String { return error }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.prefix(160))
    }
}

enum FormEncoding {
    /// `application/x-www-form-urlencoded` body. Only unreserved characters are left unescaped.
    static func encode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.keys.sorted().map { key in
            let value = fields[key] ?? ""
            return "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)="
                + "\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

enum Base64URL {
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func encode(_ text: String) -> String { encode(Array(text.utf8)) }

    static func decode(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
