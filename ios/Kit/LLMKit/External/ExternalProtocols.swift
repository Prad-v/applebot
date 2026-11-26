import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One message in the multi-turn transcript the external providers understand.
public enum ExternalMessage: Sendable, Equatable {
    case system(String)
    case user(String)
    case assistant(text: String, toolCalls: [ExternalToolCall])
    case toolResult(toolCallId: String, content: String)
}

/// A tool the model asked to run. `argumentsJSON` is accumulated from streamed fragments.
public struct ExternalToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String = "") {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// Flat string arguments for `ToolSpec` handlers.
    public var toolArguments: ToolArguments {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ToolArguments()
        }
        var values: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let text as String: values[key] = text
            case let bool as Bool: values[key] = bool ? "true" : "false"
            case let int as Int: values[key] = String(int)
            case let double as Double: values[key] = String(double)
            default:
                // Apple platforms often box numbers as NSNumber.
                if let number = value as? NSNumber {
                    values[key] = number.stringValue
                } else if JSONSerialization.isValidJSONObject([value]),
                          let encoded = try? JSONSerialization.data(withJSONObject: value),
                          let text = String(data: encoded, encoding: .utf8) {
                    values[key] = text
                }
            }
        }
        return ToolArguments(values)
    }
}

public enum ExternalFinishReason: Sendable, Equatable {
    case stop
    case toolCalls
    case length
    case other
}

/// Parsed pieces of a provider SSE stream.
public enum ExternalStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCallStart(index: Int, id: String, name: String)
    case toolCallArgumentsDelta(index: Int, json: String)
    case finished(ExternalFinishReason)
    case error(String)
}

/// Builds requests and turns SSE lines into `ExternalStreamEvent`s for one provider.
public protocol ExternalProviderAdapter: Sendable {
    var provider: ExternalProvider { get }
    func makeRequest(
        config: ExternalModelConfig,
        messages: [ExternalMessage],
        tools: [ToolSpec],
        temperature: Double?,
        maximumResponseTokens: Int?
    ) throws -> URLRequest
    func parseLine(_ line: String) -> [ExternalStreamEvent]
}

// MARK: - Shared helpers

enum ExternalJSON {
    static func toolSchema(for tools: [ToolSpec]) -> [[String: Any]] {
        tools.map { tool in
            var properties: [String: Any] = [:]
            var required: [String] = []
            for parameter in tool.parameters {
                properties[parameter.name] = [
                    "type": parameter.kind == .integer ? "integer" : "string",
                    "description": parameter.description,
                ]
                if parameter.required { required.append(parameter.name) }
            }
            return [
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ] as [String: Any],
            ]
        }
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw LLMEngineError.other("Could not encode the request.")
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func ssePayload(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return nil }
        return String(payload)
    }

    static func httpError(status: Int, body: String) -> LLMEngineError {
        let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String
        if let data = snippet.data(using: .utf8),
           let object = object(from: data) {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                detail = message
            } else if let message = object["message"] as? String, !message.isEmpty {
                detail = message
            } else {
                detail = snippet.isEmpty ? "HTTP \(status)" : String(snippet.prefix(240))
            }
        } else {
            detail = snippet.isEmpty ? "HTTP \(status)" : String(snippet.prefix(240))
        }
        switch status {
        case 401, 403:
            return .unavailable("The API key was rejected (\(detail)).")
        case 429:
            return .other("The provider rate-limited the request. Try again in a moment.")
        case 400 where detail.localizedCaseInsensitiveContains("context"):
            return .contextOverflow
        default:
            return .other("The provider returned an error (\(status)): \(detail)")
        }
    }
}

// MARK: - OpenAI (Chat Completions, including OpenAI-compatible servers)

public struct OpenAIAdapter: ExternalProviderAdapter {
    public let provider: ExternalProvider = .openAI

    public init() {}

    public func makeRequest(
        config: ExternalModelConfig,
        messages: [ExternalMessage],
        tools: [ToolSpec],
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil
    ) throws -> URLRequest {
        guard let url = config.endpoint else {
            throw LLMEngineError.unavailable(config.problem ?? "Invalid base URL.")
        }
        var body: [String: Any] = [
            "model": config.effectiveModel,
            "stream": true,
            "messages": try messages.map(Self.encodeMessage),
        ]
        if let temperature { body["temperature"] = temperature }
        if let maximumResponseTokens { body["max_tokens"] = maximumResponseTokens }
        if !tools.isEmpty {
            body["tools"] = ExternalJSON.toolSchema(for: tools).map { schema in
                ["type": "function", "function": schema] as [String: Any]
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try ExternalJSON.encode(body)
        return request
    }

    public func parseLine(_ line: String) -> [ExternalStreamEvent] {
        guard let payload = ExternalJSON.ssePayload(line),
              let data = payload.data(using: .utf8),
              let object = ExternalJSON.object(from: data) else { return [] }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return [.error(message)]
        }

        var events: [ExternalStreamEvent] = []
        if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
            if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty {
                    events.append(.textDelta(text))
                }
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for call in toolCalls {
                        let index = call["index"] as? Int ?? 0
                        let id = call["id"] as? String ?? ""
                        let function = call["function"] as? [String: Any] ?? [:]
                        let name = function["name"] as? String ?? ""
                        if !id.isEmpty || !name.isEmpty {
                            events.append(.toolCallStart(index: index, id: id, name: name))
                        }
                        if let args = function["arguments"] as? String, !args.isEmpty {
                            events.append(.toolCallArgumentsDelta(index: index, json: args))
                        }
                    }
                }
            }
            if let reason = choice["finish_reason"] as? String {
                events.append(.finished(Self.finishReason(reason)))
            }
        }
        return events
    }

    private static func finishReason(_ raw: String) -> ExternalFinishReason {
        switch raw {
        case "stop": return .stop
        case "tool_calls", "function_call": return .toolCalls
        case "length": return .length
        default: return .other
        }
    }

    private static func encodeMessage(_ message: ExternalMessage) throws -> [String: Any] {
        switch message {
        case .system(let text):
            return ["role": "system", "content": text]
        case .user(let text):
            return ["role": "user", "content": text]
        case .assistant(let text, let toolCalls):
            var encoded: [String: Any] = ["role": "assistant", "content": text]
            if !toolCalls.isEmpty {
                encoded["tool_calls"] = toolCalls.enumerated().map { index, call in
                    [
                        "id": call.id,
                        "index": index,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON,
                        ],
                    ] as [String: Any]
                }
            }
            return encoded
        case .toolResult(let id, let content):
            return ["role": "tool", "tool_call_id": id, "content": content]
        }
    }
}

// MARK: - Anthropic Messages API

public struct AnthropicAdapter: ExternalProviderAdapter {
    public let provider: ExternalProvider = .anthropic
    public var maxTokens: Int
    public var apiVersion: String

    public init(maxTokens: Int = 4096, apiVersion: String = "2023-06-01") {
        self.maxTokens = maxTokens
        self.apiVersion = apiVersion
    }

    public func makeRequest(
        config: ExternalModelConfig,
        messages: [ExternalMessage],
        tools: [ToolSpec],
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil
    ) throws -> URLRequest {
        guard let url = config.endpoint else {
            throw LLMEngineError.unavailable(config.problem ?? "Invalid base URL.")
        }

        var systemText = ""
        var chat: [[String: Any]] = []
        for message in messages {
            switch message {
            case .system(let text):
                if !systemText.isEmpty { systemText += "\n\n" }
                systemText += text
            case .user(let text):
                chat.append(["role": "user", "content": text])
            case .assistant(let text, let toolCalls):
                var blocks: [[String: Any]] = []
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                for call in toolCalls {
                    let input = Self.jsonObject(call.argumentsJSON) ?? [:]
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": input,
                    ])
                }
                chat.append(["role": "assistant", "content": blocks])
            case .toolResult(let id, let content):
                // Anthropic wants tool results as a user message. Merge consecutive results.
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": content,
                ]
                if var last = chat.last, last["role"] as? String == "user",
                   var existing = last["content"] as? [[String: Any]] {
                    existing.append(block)
                    last["content"] = existing
                    chat[chat.count - 1] = last
                } else {
                    chat.append(["role": "user", "content": [block]])
                }
            }
        }

        var body: [String: Any] = [
            "model": config.effectiveModel,
            "max_tokens": maximumResponseTokens ?? maxTokens,
            "stream": true,
            "messages": chat,
        ]
        if let temperature { body["temperature"] = temperature }
        if !systemText.isEmpty { body["system"] = systemText }
        if !tools.isEmpty {
            body["tools"] = ExternalJSON.toolSchema(for: tools).map { schema -> [String: Any] in
                [
                    "name": schema["name"] as? String ?? "",
                    "description": schema["description"] as? String ?? "",
                    "input_schema": schema["parameters"] as? [String: Any] ?? ["type": "object"],
                ]
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.trimmedKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try ExternalJSON.encode(body)
        return request
    }

    public func parseLine(_ line: String) -> [ExternalStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Anthropic uses named SSE events; we only need the `data:` payloads.
        guard let payload = ExternalJSON.ssePayload(trimmed),
              let data = payload.data(using: .utf8),
              let object = ExternalJSON.object(from: data) else { return [] }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return [.error(message)]
        }

        let type = object["type"] as? String ?? ""
        switch type {
        case "content_block_start":
            guard let block = object["content_block"] as? [String: Any],
                  let index = object["index"] as? Int else { return [] }
            if block["type"] as? String == "tool_use" {
                return [.toolCallStart(
                    index: index,
                    id: block["id"] as? String ?? "",
                    name: block["name"] as? String ?? ""
                )]
            }
            return []
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  let index = object["index"] as? Int else { return [] }
            if let text = delta["text"] as? String, !text.isEmpty {
                return [.textDelta(text)]
            }
            if let partial = delta["partial_json"] as? String, !partial.isEmpty {
                return [.toolCallArgumentsDelta(index: index, json: partial)]
            }
            return []
        case "message_delta":
            if let delta = object["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                return [.finished(Self.finishReason(reason))]
            }
            return []
        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String
                ?? "The provider returned an error."
            return [.error(message)]
        default:
            return []
        }
    }

    private static func finishReason(_ raw: String) -> ExternalFinishReason {
        switch raw {
        case "end_turn", "stop_sequence": return .stop
        case "tool_use": return .toolCalls
        case "max_tokens": return .length
        default: return .other
        }
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [:] }
        return ExternalJSON.object(from: data)
    }
}

public enum ExternalAdapters {
    public static func adapter(for provider: ExternalProvider) -> any ExternalProviderAdapter {
        switch provider {
        case .openAI: return OpenAIAdapter()
        case .anthropic: return AnthropicAdapter()
        }
    }
}
