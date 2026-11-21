import Foundation

/// One message in a conversation.
public struct Turn: Sendable, Codable, Equatable, Hashable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// Everything an engine needs for a single generation call.
///
/// History is rendered into the prompt text by `PromptBuilder` (rather than relying on
/// the model session's own transcript) so that `ContextManager` has full control over
/// what fits in the small context window.
public struct LLMRequest: Sendable, Equatable {
    public var instructions: String
    public var prompt: String
    /// Optional sampling temperature (higher = more varied). Engines that do not support it ignore this.
    public var temperature: Double?

    public init(instructions: String, prompt: String, temperature: Double? = nil) {
        self.instructions = instructions
        self.prompt = prompt
        self.temperature = temperature
    }
}

/// Errors every engine maps its native failures onto.
public enum LLMEngineError: Error, Sendable, Equatable {
    /// Instructions + prompt + answer did not fit in the context window.
    case contextOverflow
    /// The model refused for safety reasons.
    case guardrail
    /// The model cannot be used right now (see `EngineAvailability`).
    case unavailable(String)
    /// Unsupported language or locale.
    case unsupportedLanguage
    /// Anything else.
    case other(String)
}

extension LLMEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .contextOverflow:
            return "The conversation is too long for the model."
        case .guardrail:
            return "I can't help with that one, but I'm happy to try if you put it another way."
        case .unavailable(let why):
            return "The model is unavailable: \(why)"
        case .unsupportedLanguage:
            return "This language is not supported by the model."
        case .other(let message):
            return message
        }
    }
}

/// Whether the underlying model can currently answer.
public enum EngineAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case unavailable(String)

    public var isAvailable: Bool { self == .available }

    /// Short human-readable explanation for banners and settings.
    public var message: String {
        switch self {
        case .available:
            return "Apple Intelligence model ready"
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence."
        case .appleIntelligenceDisabled:
            return "Turn on Apple Intelligence in Settings to chat."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again soon."
        case .unavailable(let why):
            return why
        }
    }
}

/// A text-generation backend.
///
/// `stream` yields the **cumulative** response text so far (not token deltas), matching
/// the Foundation Models streaming behaviour. The final element is the complete answer.
public protocol LLMEngine: Sendable {
    func availability() -> EngineAvailability
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

public extension LLMEngine {
    func availability() -> EngineAvailability { .available }

    /// Convenience: run to completion and return the final text.
    func respond(_ request: LLMRequest) async throws -> String {
        var last = ""
        for try await snapshot in stream(request) {
            last = snapshot
        }
        return last
    }
}
