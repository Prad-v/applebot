import Foundation

/// A cloud model provider the user can switch to instead of the on-device model.
public enum ExternalProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    /// OpenAI, or any server that speaks the OpenAI Chat Completions API (set a custom base URL).
    case openAI = "openai"
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        }
    }

    /// Pre-filled model name. It is a plain text field in the app, so any model the account can use works.
    public var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-5-5"
        }
    }

    /// Shown as one-tap suggestions next to the model field.
    public var suggestedModels: [String] {
        switch self {
        case .openAI: return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1", "o4-mini"]
        case .anthropic: return ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .openAI: return "sk-…"
        case .anthropic: return "sk-ant-…"
        }
    }

    /// Where the user creates an API key.
    public var keysPage: String {
        switch self {
        case .openAI: return "https://platform.openai.com/api-keys"
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        }
    }

    /// Path appended to the base URL.
    var endpointPath: String {
        switch self {
        case .openAI: return "/chat/completions"
        case .anthropic: return "/messages"
        }
    }
}

/// Everything needed to call one provider. The key is a secret: it is held here only in memory and is
/// persisted exclusively through a `SecretStore` (the Keychain in the app).
public struct ExternalModelConfig: Sendable, Equatable {
    public var provider: ExternalProvider
    public var model: String
    /// Empty means the provider default. Lets users point at a proxy or an OpenAI-compatible server.
    public var baseURL: String
    public var apiKey: String

    public init(provider: ExternalProvider, model: String = "", baseURL: String = "", apiKey: String = "") {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The model to call: what the user typed, else the provider default.
    public var effectiveModel: String { trimmedModel.isEmpty ? provider.defaultModel : trimmedModel }

    public var effectiveBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultBaseURL : trimmed
    }

    /// Why this configuration cannot be used, or nil when it is ready.
    public var problem: String? {
        if trimmedKey.isEmpty { return "Add your \(provider.displayName) API key." }
        if trimmedKey.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return "The API key contains spaces or line breaks. Paste it again."
        }
        return Self.validate(baseURL: effectiveBaseURL)
    }

    public var isReady: Bool { problem == nil }

    /// The full request URL (base URL + the provider's path), if the base URL is valid.
    public var endpoint: URL? {
        guard Self.validate(baseURL: effectiveBaseURL) == nil else { return nil }
        var base = effectiveBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + provider.endpointPath)
    }

    /// The API key travels in a header, so it must never go over plain HTTP to a remote host.
    /// Plain HTTP is accepted only for this device and the local network (for example Ollama on a Mac).
    public static func validate(baseURL: String) -> String? {
        guard let components = URLComponents(string: baseURL), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else {
            return "The base URL is not a valid web address."
        }
        switch scheme {
        case "https":
            return nil
        case "http":
            return isLocalHost(host) ? nil : "Use https:// for the base URL. Plain http is only allowed for localhost and local-network addresses."
        default:
            return "The base URL must start with https://."
        }
    }

    static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
