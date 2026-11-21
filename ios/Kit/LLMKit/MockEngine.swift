import Foundation

/// A scripted engine for unit tests, previews, and simulators without Apple Intelligence.
///
/// Scripts are consumed in order, one per `stream` call. When the queue is empty the
/// `fallback` closure produces the reply (default: echoes the last line of the prompt).
///
/// It also conforms to `ToolCallingEngine`: a `.useTools` script invokes the named tools (through
/// whatever wrappers the caller supplied) and then replies, so tests can exercise the whole
/// tool path (approval, output trimming, activity events) without a real model.
public final class MockEngine: ToolCallingEngine, @unchecked Sendable {
    public struct ToolCall: Sendable, Equatable {
        public var name: String
        public var arguments: [String: String]

        public init(_ name: String, _ arguments: [String: String] = [:]) {
            self.name = name
            self.arguments = arguments
        }
    }

    public enum Script: Sendable {
        case reply(String)
        case fail(LLMEngineError)
        /// Call each tool in order, then reply. `reply` may use `{results}` to embed what the tools returned.
        case useTools([ToolCall], reply: String)
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private var recorded: [LLMRequest] = []
    private var recordedToolNames: [[String]] = []
    private var recordedToolResults: [String] = []
    private let chunkSize: Int
    private let delayNanoseconds: UInt64
    private let status: EngineAvailability
    private let fallback: @Sendable (LLMRequest) -> String

    public init(
        scripts: [Script] = [],
        availability: EngineAvailability = .available,
        chunkSize: Int = 8,
        delayNanoseconds: UInt64 = 0,
        fallback: @escaping @Sendable (LLMRequest) -> String = { request in
            "Mock reply to: " + (request.prompt.split(separator: "\n").last.map(String.init) ?? "")
        }
    ) {
        self.scripts = scripts
        self.status = availability
        self.chunkSize = max(1, chunkSize)
        self.delayNanoseconds = delayNanoseconds
        self.fallback = fallback
    }

    /// Every request the engine has received, in order.
    public var requests: [LLMRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// The tool names offered on each request (empty array for requests without tools).
    public var offeredToolNames: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recordedToolNames
    }

    /// Everything tools returned to the "model" through `.useTools` scripts, in order.
    public var toolResults: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedToolResults
    }

    public func enqueue(_ script: Script) {
        lock.lock(); defer { lock.unlock() }
        scripts.append(script)
    }

    public func availability() -> EngineAvailability { status }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        stream(request, tools: [])
    }

    public func stream(_ request: LLMRequest, tools: [ToolSpec]) -> AsyncThrowingStream<String, Error> {
        let script: Script = {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            recordedToolNames.append(tools.map(\.name))
            return scripts.isEmpty ? .reply(fallback(request)) : scripts.removeFirst()
        }()
        let chunkSize = self.chunkSize
        let delay = self.delayNanoseconds

        return AsyncThrowingStream { continuation in
            let task = Task {
                var text: String
                switch script {
                case .fail(let error):
                    continuation.finish(throwing: error)
                    return
                case .reply(let reply):
                    text = reply
                case .useTools(let calls, let reply):
                    var results: [String] = []
                    for call in calls {
                        let output: String
                        if let tool = tools.first(where: { $0.name == call.name }) {
                            output = (try? await tool.handler(ToolArguments(call.arguments))) ?? "Error"
                        } else {
                            output = "Unknown tool \(call.name)"
                        }
                        results.append(output)
                        self.record(toolResult: output)
                    }
                    text = reply.replacingOccurrences(of: "{results}", with: results.joined(separator: "\n"))
                }

                var shown = ""
                var remaining = Substring(text)
                while !remaining.isEmpty {
                    if Task.isCancelled { continuation.finish(); return }
                    let piece = remaining.prefix(chunkSize)
                    shown += piece
                    remaining = remaining.dropFirst(piece.count)
                    continuation.yield(shown)
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                }
                if text.isEmpty { continuation.yield("") }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(toolResult: String) {
        lock.lock(); defer { lock.unlock() }
        recordedToolResults.append(toolResult)
    }
}
