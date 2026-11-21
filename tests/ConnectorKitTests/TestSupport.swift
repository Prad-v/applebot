import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ConnectorKit

/// Scripted `HTTPClient`: the handler gets each request and returns (status, body).
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private let lock = NSLock()
    private var log: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    convenience init(json routes: [String: (Int, Any)]) {
        // Serialise up front: the handler must be Sendable and `Any` is not.
        let prepared: [(suffix: String, status: Int, data: Data)] = routes.map { suffix, response in
            (suffix, response.0, (try? JSONSerialization.data(withJSONObject: response.1)) ?? Data())
        }
        self.init { request in
            let path = request.url?.path ?? ""
            for route in prepared where path.hasSuffix(route.suffix) {
                return (route.status, route.data)
            }
            return (404, Data("{\"error\":{\"message\":\"no route for \(path)\"}}".utf8))
        }
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        log.append(request)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (status, data) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

/// Plays the browser: returns a redirect carrying the `state` from the authorization URL.
struct ScriptedWeb: WebAuthenticator {
    enum Outcome: Sendable {
        case approve(code: String)
        case approveWithWrongState
        case denied
        case providerError(String)
        case cancelled
    }

    let outcome: Outcome
    var onAuthorize: @Sendable (URL) -> Void = { _ in }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        onAuthorize(url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value ?? ""
        switch outcome {
        case .approve(let code):
            return URL(string: "\(callbackScheme):/oauth2redirect?code=\(code)&state=\(state)")!
        case .approveWithWrongState:
            return URL(string: "\(callbackScheme):/oauth2redirect?code=abc&state=forged")!
        case .denied:
            return URL(string: "\(callbackScheme):/oauth2redirect?error=access_denied&state=\(state)")!
        case .providerError(let message):
            return URL(string: "\(callbackScheme):/oauth2redirect?error=server_error&error_description=\(message)&state=\(state)")!
        case .cancelled:
            throw ConnectorError.cancelled
        }
    }
}

extension URLRequest {
    var formFields: [String: String] {
        guard let body = httpBody, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return fields
    }

    var queryDictionary: [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}
