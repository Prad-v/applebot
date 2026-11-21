#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// `LLMEngine` backed by Apple's on-device system language model (Apple Intelligence).
///
/// A fresh `LanguageModelSession` is created per request. Conversation history, the rolling
/// summary and retrieved context are rendered into the prompt by `PromptBuilder` /
/// `ContextManager`, so we control exactly what occupies the ~4K token window.
@available(iOS 26.0, macOS 26.0, *)
public struct AppleFMEngine: ToolCallingEngine {
    public init() {}

    public func availability() -> EngineAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceDisabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .unavailable("The on-device model is unavailable.")
            }
        }
    }

    /// Warm the model so the first token arrives faster. Safe to call repeatedly.
    public func prewarm(instructions: String) {
        guard availability().isAvailable else { return }
        LanguageModelSession(instructions: instructions).prewarm()
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        stream(request, tools: [])
    }

    public func stream(_ request: LLMRequest, tools: [ToolSpec]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let status = availability()
                    guard status.isAvailable else {
                        throw LLMEngineError.unavailable(status.message)
                    }
                    let session = LanguageModelSession(
                        tools: try tools.map { try DynamicTool($0) },
                        instructions: request.instructions
                    )
                    let options: GenerationOptions
                    if let temperature = request.temperature {
                        options = GenerationOptions(temperature: temperature)
                    } else {
                        options = GenerationOptions()
                    }
                    for try await snapshot in session.streamResponse(to: request.prompt, options: options) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Adapts a portable `ToolSpec` to a FoundationModels `Tool` using a runtime-built schema, so
    /// connectors can define tools as data instead of `@Generable` types.
    struct DynamicTool: FoundationModels.Tool {
        typealias Arguments = GeneratedContent
        typealias Output = String

        let spec: ToolSpec
        let parameters: GenerationSchema

        var name: String { spec.name }
        var description: String { spec.description }

        init(_ spec: ToolSpec) throws {
            self.spec = spec
            let properties = spec.parameters.map { parameter in
                DynamicGenerationSchema.Property(
                    name: parameter.name,
                    description: parameter.description,
                    schema: parameter.kind == .integer
                        ? DynamicGenerationSchema(type: Int.self)
                        : DynamicGenerationSchema(type: String.self),
                    isOptional: !parameter.required
                )
            }
            let root = DynamicGenerationSchema(
                name: "\(spec.name)_arguments", description: spec.description, properties: properties
            )
            parameters = try GenerationSchema(root: root, dependencies: [])
        }

        func call(arguments: GeneratedContent) async throws -> String {
            var values: [String: String] = [:]
            for parameter in spec.parameters {
                switch parameter.kind {
                case .integer:
                    if let number = try? arguments.value(Int.self, forProperty: parameter.name) {
                        values[parameter.name] = String(number)
                    }
                case .string:
                    if let text = try? arguments.value(String.self, forProperty: parameter.name) {
                        values[parameter.name] = text
                    }
                }
            }
            return try await spec.handler(ToolArguments(values))
        }
    }

    static func map(_ error: Error) -> Error {
        if let engineError = error as? LLMEngineError { return engineError }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                return LLMEngineError.contextOverflow
            case .guardrailViolation:
                return LLMEngineError.guardrail
            case .unsupportedLanguageOrLocale:
                return LLMEngineError.unsupportedLanguage
            default:
                return LLMEngineError.other(generation.localizedDescription)
            }
        }
        return LLMEngineError.other(error.localizedDescription)
    }
}
#endif
