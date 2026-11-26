import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `LLMEngine` that talks to OpenAI or Anthropic (or an OpenAI-compatible server) over HTTPS.
///
/// Streaming yields **cumulative** text, matching `AppleFMEngine`. When tools are offered, the
/// engine runs a short request/tool/request loop itself: each provider returns tool-call fragments
/// in the SSE stream, the handlers run locally (with `ToolGuard` wrapping from `ChatPipeline`),
/// and another request is made with the results until the model stops or the round limit is hit.
public struct ExternalEngine: ToolCallingEngine {
    public var config: ExternalModelConfig
    public var transport: any StreamingTransport
    public var adapter: any ExternalProviderAdapter
    /// Safety cap on request → tool → request cycles for one answer.
    public var maxRounds: Int

    public init(
        config: ExternalModelConfig,
        transport: any StreamingTransport = URLSessionStreamingTransport(),
        adapter: (any ExternalProviderAdapter)? = nil,
        maxRounds: Int = 8
    ) {
        self.config = config
        self.transport = transport
        self.adapter = adapter ?? ExternalAdapters.adapter(for: config.provider)
        self.maxRounds = max(1, maxRounds)
    }

    public func availability() -> EngineAvailability {
        if let problem = config.problem {
            return .unavailable(problem)
        }
        return .available
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        stream(request, tools: [])
    }

    public func stream(_ request: LLMRequest, tools: [ToolSpec]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    if let problem = config.problem {
                        throw LLMEngineError.unavailable(problem)
                    }
                    var messages: [ExternalMessage] = [
                        .system(request.instructions),
                        .user(request.prompt),
                    ]
                    let shown = TextAccumulator()
                    for _ in 0..<maxRounds {
                        try Task.checkCancellation()
                        let turn = try await runRound(
                            messages: messages,
                            tools: tools,
                            temperature: request.temperature,
                            maximumResponseTokens: request.maximumResponseTokens
                        ) { delta in
                            continuation.yield(shown.append(delta))
                        }
                        if turn.toolCalls.isEmpty {
                            if shown.value.isEmpty { continuation.yield("") }
                            continuation.finish()
                            return
                        }
                        messages.append(.assistant(text: turn.text, toolCalls: turn.toolCalls))
                        for call in turn.toolCalls {
                            let output = await Self.invoke(call, tools: tools)
                            messages.append(.toolResult(toolCallId: call.id, content: output))
                        }
                    }
                    throw LLMEngineError.other("The model kept calling tools without finishing. Try again.")
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Mutable string box so streaming callbacks stay `@Sendable` under Swift 6.
    private final class TextAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        var value: String {
            lock.lock(); defer { lock.unlock() }
            return text
        }
        func append(_ delta: String) -> String {
            lock.lock(); defer { lock.unlock() }
            text += delta
            return text
        }
    }

    // MARK: -

    private struct Round {
        var text: String
        var toolCalls: [ExternalToolCall]
    }

    private func runRound(
        messages: [ExternalMessage],
        tools: [ToolSpec],
        temperature: Double?,
        maximumResponseTokens: Int?,
        onDelta: @Sendable (String) -> Void
    ) async throws -> Round {
        let request = try adapter.makeRequest(
            config: config,
            messages: messages,
            tools: tools,
            temperature: temperature,
            maximumResponseTokens: maximumResponseTokens
        )
        let response = try await transport.open(request)

        var pendingErrorBody = ""
        var text = ""
        var toolCalls: [Int: ExternalToolCall] = [:]
        var finished: ExternalFinishReason?

        if !(200...299).contains(response.status) {
            // Drain the body so the error message can include it.
            for try await line in response.lines {
                if let payload = ExternalJSON.ssePayload(line) {
                    pendingErrorBody += payload
                } else {
                    pendingErrorBody += line
                }
            }
            throw ExternalJSON.httpError(status: response.status, body: pendingErrorBody)
        }

        for try await line in response.lines {
            try Task.checkCancellation()
            for event in adapter.parseLine(line) {
                switch event {
                case .textDelta(let delta):
                    text += delta
                    onDelta(delta)
                case .toolCallStart(let index, let id, let name):
                    var call = toolCalls[index] ?? ExternalToolCall(id: "", name: "")
                    if !id.isEmpty { call.id = id }
                    if !name.isEmpty { call.name = name }
                    if call.id.isEmpty { call.id = "call_\(index)" }
                    toolCalls[index] = call
                case .toolCallArgumentsDelta(let index, let json):
                    var call = toolCalls[index] ?? ExternalToolCall(id: "call_\(index)", name: "")
                    call.argumentsJSON += json
                    toolCalls[index] = call
                case .finished(let reason):
                    finished = reason
                case .error(let message):
                    throw LLMEngineError.other(message)
                }
            }
        }

        let ordered = toolCalls.keys.sorted().compactMap { toolCalls[$0] }.filter { !$0.name.isEmpty }
        if finished == .length {
            throw LLMEngineError.contextOverflow
        }
        // Some servers omit finish_reason but still return tool calls.
        if finished == nil, !ordered.isEmpty {
            finished = .toolCalls
        }
        return Round(text: text, toolCalls: finished == .toolCalls ? ordered : [])
    }

    private static func invoke(_ call: ExternalToolCall, tools: [ToolSpec]) async -> String {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return "Unknown tool \(call.name)"
        }
        do {
            return try await tool.handler(call.toolArguments)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return "Error: \(message)"
        }
    }
}
