import XCTest
@testable import LLMKit

final class ExternalModelConfigTests: XCTestCase {
    func testMissingKeyIsNotReady() {
        let config = ExternalModelConfig(provider: .openAI, apiKey: "  ")
        XCTAssertEqual(config.problem, "Add your OpenAI API key.")
        XCTAssertFalse(config.isReady)
    }

    func testKeyWithWhitespaceIsRejected() {
        let config = ExternalModelConfig(provider: .anthropic, apiKey: "sk-ant bad")
        XCTAssertEqual(config.problem, "The API key contains spaces or line breaks. Paste it again.")
    }

    func testDefaultsFillModelAndBaseURL() {
        let config = ExternalModelConfig(provider: .anthropic, apiKey: "sk-ant-test")
        XCTAssertEqual(config.effectiveModel, "claude-sonnet-5-5")
        XCTAssertEqual(config.effectiveBaseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(config.endpoint?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertNil(config.problem)
    }

    func testRemoteHTTPIsRejectedButLocalhostIsAllowed() {
        XCTAssertNotNil(ExternalModelConfig.validate(baseURL: "http://example.com/v1"))
        XCTAssertNil(ExternalModelConfig.validate(baseURL: "http://localhost:11434/v1"))
        XCTAssertNil(ExternalModelConfig.validate(baseURL: "http://192.168.1.10:8080/v1"))
        XCTAssertNil(ExternalModelConfig.validate(baseURL: "https://api.openai.com/v1"))
    }

    func testOpenAIEndpointUsesChatCompletions() {
        let config = ExternalModelConfig(provider: .openAI, apiKey: "sk-test")
        XCTAssertEqual(config.endpoint?.absoluteString, "https://api.openai.com/v1/chat/completions")
    }
}

final class ExternalModelStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var secrets: InMemorySecretStore!
    private var store: ExternalModelStore!

    override func setUp() {
        suiteName = "ExternalModelStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = InMemorySecretStore()
        store = ExternalModelStore(defaults: defaults, secrets: secrets)
    }

    override func tearDown() {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        defaults = nil
        secrets = nil
        store = nil
        suiteName = nil
    }

    func testActiveConfigNilUntilEnabledAndReady() throws {
        XCTAssertNil(store.activeConfig())
        try store.save(ExternalModelConfig(provider: .openAI, model: "gpt-4o-mini", apiKey: "sk-test"))
        XCTAssertNil(store.activeConfig())
        store.isEnabled = true
        store.selectedProvider = .openAI
        let active = store.activeConfig()
        XCTAssertEqual(active?.effectiveModel, "gpt-4o-mini")
        XCTAssertEqual(active?.apiKey, "sk-test")
    }

    func testProviderSettingsAreIndependent() throws {
        try store.save(ExternalModelConfig(provider: .openAI, model: "gpt-4o", apiKey: "sk-openai"))
        try store.save(ExternalModelConfig(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "sk-ant"))
        XCTAssertEqual(store.config(for: .openAI).apiKey, "sk-openai")
        XCTAssertEqual(store.config(for: .anthropic).model, "claude-haiku-5-5")
        store.selectedProvider = .anthropic
        store.isEnabled = true
        XCTAssertEqual(store.activeConfig()?.provider, .anthropic)
    }

    func testEmptyKeyRemovesSecret() throws {
        try store.save(ExternalModelConfig(provider: .openAI, apiKey: "sk-keep"))
        try store.save(ExternalModelConfig(provider: .openAI, apiKey: ""))
        XCTAssertEqual(store.config(for: .openAI).apiKey, "")
    }

    func testResetClearsEverything() throws {
        store.isEnabled = true
        store.selectedProvider = .anthropic
        try store.save(ExternalModelConfig(provider: .anthropic, model: "x", apiKey: "sk"))
        store.reset()
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.selectedProvider, .openAI)
        XCTAssertEqual(store.config(for: .anthropic).apiKey, "")
        XCTAssertNil(store.activeConfig())
    }
}

final class ExternalAdapterTests: XCTestCase {
    func testOpenAIRequestShape() throws {
        let adapter = OpenAIAdapter()
        let config = ExternalModelConfig(provider: .openAI, model: "gpt-4o-mini", apiKey: "sk-test")
        let tool = ToolSpec(name: "ping", description: "Ping", parameters: [
            ToolParameter("host", "Host name"),
        ]) { _ in "ok" }
        let request = try adapter.makeRequest(
            config: config,
            messages: [.system("sys"), .user("hi")],
            tools: [tool],
            temperature: 0.35,
            maximumResponseTokens: 400
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(request.httpBody.flatMap {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["temperature"] as? Double, 0.35)
        XCTAssertEqual(body["max_tokens"] as? Int, 400)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
    }

    func testOpenAIParsesContentAndToolCallFragments() {
        let adapter = OpenAIAdapter()
        let start = adapter.parseLine(
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"ping","arguments":""}}]}}]}"#
        )
        XCTAssertEqual(start, [.toolCallStart(index: 0, id: "call_1", name: "ping")])
        let args = adapter.parseLine(
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"host\":\"a\"}"}}]}}]}"#
        )
        XCTAssertEqual(args, [.toolCallArgumentsDelta(index: 0, json: #"{"host":"a"}"#)])
        let text = adapter.parseLine(
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        )
        XCTAssertEqual(text, [.textDelta("Hello")])
        let done = adapter.parseLine(
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#
        )
        XCTAssertEqual(done, [.finished(.toolCalls)])
        XCTAssertTrue(adapter.parseLine("data: [DONE]").isEmpty)
    }

    func testAnthropicRequestShapeAndToolResults() throws {
        let adapter = AnthropicAdapter()
        let config = ExternalModelConfig(provider: .anthropic, apiKey: "sk-ant")
        let request = try adapter.makeRequest(
            config: config,
            messages: [
                .system("sys"),
                .user("hi"),
                .assistant(text: "", toolCalls: [ExternalToolCall(id: "toolu_1", name: "ping", argumentsJSON: #"{"host":"a"}"#)]),
                .toolResult(toolCallId: "toolu_1", content: "pong"),
            ],
            tools: [ToolSpec(name: "ping", description: "Ping") { _ in "pong" }]
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(request.httpBody.flatMap {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        XCTAssertEqual(body["system"] as? String, "sys")
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[2]["role"] as? String, "user")
    }

    func testAnthropicParsesTextAndToolUseEvents() {
        let adapter = AnthropicAdapter()
        let start = adapter.parseLine(
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"ping","input":{}}}"#
        )
        XCTAssertEqual(start, [.toolCallStart(index: 1, id: "toolu_1", name: "ping")])
        let delta = adapter.parseLine(
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
        )
        XCTAssertEqual(delta, [.textDelta("Hi")])
        let json = adapter.parseLine(
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"x\":1}"}}"#
        )
        XCTAssertEqual(json, [.toolCallArgumentsDelta(index: 1, json: #"{"x":1}"#)])
        let stop = adapter.parseLine(
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#
        )
        XCTAssertEqual(stop, [.finished(.stop)])
    }
}

final class ExternalEngineTests: XCTestCase {
    func testStreamsCumulativeTextFromOpenAI() async throws {
        let transport = MockStreamingTransport(replies: [
            .init(lines: [
                #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
                #"data: {"choices":[{"delta":{"content":"lo"}}]}"#,
                #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
                "data: [DONE]",
            ]),
        ])
        let engine = ExternalEngine(
            config: ExternalModelConfig(provider: .openAI, apiKey: "sk-test"),
            transport: transport
        )
        let answer = try await engine.respond(LLMRequest(instructions: "Be brief.", prompt: "Hi"))
        XCTAssertEqual(answer, "Hello")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testToolLoopRunsHandlerAndContinues() async throws {
        let transport = MockStreamingTransport(replies: [
            .init(lines: [
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"echo","arguments":"{\"text\":\"hi\"}"}}]}}]}"#,
                #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
                "data: [DONE]",
            ]),
            .init(lines: [
                #"data: {"choices":[{"delta":{"content":"Tool said hi"}}]}"#,
                #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
                "data: [DONE]",
            ]),
        ])
        let engine = ExternalEngine(
            config: ExternalModelConfig(provider: .openAI, apiKey: "sk-test"),
            transport: transport
        )
        let tool = ToolSpec(
            name: "echo",
            description: "Echo",
            parameters: [ToolParameter("text", "Text")]
        ) { args in
            "echo:\(args.string("text") ?? "")"
        }
        let answer = try await engine.respond(
            LLMRequest(instructions: "Use tools.", prompt: "Go"),
            tools: [tool]
        )
        XCTAssertEqual(answer, "Tool said hi")
        XCTAssertEqual(transport.requests.count, 2)
        let secondBody = try XCTUnwrap(transport.requestBodies.dropFirst().first)
        let messages = try XCTUnwrap(secondBody["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { ($0["role"] as? String) == "tool" })
    }

    func testHTTPErrorSurfacesProviderMessage() async {
        let transport = MockStreamingTransport(replies: [
            .init(status: 401, lines: [#"{"error":{"message":"Incorrect API key"}}"#]),
        ])
        let engine = ExternalEngine(
            config: ExternalModelConfig(provider: .openAI, apiKey: "sk-bad"),
            transport: transport
        )
        do {
            _ = try await engine.respond(LLMRequest(instructions: "x", prompt: "y"))
            XCTFail("expected error")
        } catch let error as LLMEngineError {
            guard case .unavailable(let why) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(why.contains("Incorrect API key"), why)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testUnavailableWhenKeyMissing() async {
        let engine = ExternalEngine(config: ExternalModelConfig(provider: .anthropic))
        XCTAssertEqual(engine.availability(), .unavailable("Add your Anthropic API key."))
        do {
            _ = try await engine.respond(LLMRequest(instructions: "x", prompt: "y"))
            XCTFail("expected unavailable")
        } catch let error as LLMEngineError {
            guard case .unavailable = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAnthropicStreamingText() async throws {
        let transport = MockStreamingTransport(replies: [
            .init(lines: [
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Claude"}}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            ]),
        ])
        let engine = ExternalEngine(
            config: ExternalModelConfig(provider: .anthropic, apiKey: "sk-ant"),
            transport: transport,
            adapter: AnthropicAdapter()
        )
        let answer = try await engine.respond(LLMRequest(instructions: "sys", prompt: "hi"))
        XCTAssertEqual(answer, "Claude")
    }
}

private extension LLMEngine {
    func respond(_ request: LLMRequest, tools: [ToolSpec]) async throws -> String {
        guard let engine = self as? any ToolCallingEngine else {
            return try await respond(request)
        }
        var last = ""
        for try await snapshot in engine.stream(request, tools: tools) {
            last = snapshot
        }
        return last
    }
}
