import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An open HTTP response whose body arrives line by line (server-sent events).
public struct StreamingResponse: Sendable {
    public var status: Int
    public var lines: AsyncThrowingStream<String, Error>

    public init(status: Int, lines: AsyncThrowingStream<String, Error>) {
        self.status = status
        self.lines = lines
    }
}

/// HTTP seam for the external engines, so they can be tested without a network.
public protocol StreamingTransport: Sendable {
    func open(_ request: URLRequest) async throws -> StreamingResponse
}

/// Real transport. Uses an ephemeral session so nothing (cookies, cache) is written to disk.
public struct URLSessionStreamingTransport: StreamingTransport {
    private let session: URLSession

    /// `timeout` is the longest the connection may stay silent, not the length of the whole answer.
    public init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false
        #endif
        session = URLSession(configuration: configuration)
    }

    public func open(_ request: URLRequest) async throws -> StreamingResponse {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no streaming `bytes(for:)`: read the whole body, then split it.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMEngineError.other("The server sent an unreadable response.")
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        return StreamingResponse(status: http.statusCode, lines: AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
        #else
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMEngineError.other("The server sent an unreadable response.")
        }
        return StreamingResponse(status: http.statusCode, lines: AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        })
        #endif
    }
}

/// A scripted transport for unit tests, previews and UI tests. Each call to `open` consumes the next
/// scripted response (the last one repeats), and every request is recorded.
public final class MockStreamingTransport: StreamingTransport, @unchecked Sendable {
    public struct Reply: Sendable {
        public var status: Int
        public var lines: [String]
        public var error: LLMEngineError?

        public init(status: Int = 200, lines: [String] = [], error: LLMEngineError? = nil) {
            self.status = status
            self.lines = lines
            self.error = error
        }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []
    private let responder: (@Sendable (URLRequest) -> Reply)?

    public init(replies: [Reply] = []) {
        self.replies = replies
        self.responder = nil
    }

    /// Computes every reply from the request, for UI tests that need a canned answer on demand.
    public init(responder: @escaping @Sendable (URLRequest) -> Reply) {
        self.replies = []
        self.responder = responder
    }

    public var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// The decoded JSON bodies of the recorded requests.
    public var requestBodies: [[String: Any]] {
        requests.compactMap { request in
            request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    public func open(_ request: URLRequest) async throws -> StreamingResponse {
        let reply: Reply = {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            if let responder { return responder(request) }
            if replies.count > 1 { return replies.removeFirst() }
            return replies.first ?? Reply()
        }()
        if let error = reply.error { throw error }
        return StreamingResponse(status: reply.status, lines: AsyncThrowingStream { continuation in
            for line in reply.lines { continuation.yield(line) }
            continuation.finish()
        })
    }
}
