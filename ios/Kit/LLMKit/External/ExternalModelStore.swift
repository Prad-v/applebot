import Foundation

/// Persists the external-model settings: which provider is selected, whether the external model is
/// switched on, and each provider's model / base URL / API key.
///
/// Non-secret values live in `UserDefaults`; API keys live only in the `SecretStore` (Keychain).
/// Each provider keeps its own settings, so switching provider in the UI never loses the other's key.
public struct ExternalModelStore: Sendable {
    public enum Keys {
        public static let enabled = "externalModel.enabled"
        public static let provider = "externalModel.provider"
        static func model(_ provider: ExternalProvider) -> String { "externalModel.\(provider.rawValue).model" }
        static func baseURL(_ provider: ExternalProvider) -> String { "externalModel.\(provider.rawValue).baseURL" }
        static func apiKey(_ provider: ExternalProvider) -> String { "externalModel.\(provider.rawValue).apiKey" }
    }

    // `UserDefaults` is documented thread-safe; it is not yet marked `Sendable` on every platform.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let secrets: any SecretStore

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// The provider selected in Settings (OpenAI until the user chooses otherwise).
    public var selectedProvider: ExternalProvider {
        get { ExternalProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .openAI }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.provider) }
    }

    /// The master switch: true means chats use the external model instead of the on-device one.
    public var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    /// Saved settings for a provider (blank fields when nothing was saved yet).
    public func config(for provider: ExternalProvider) -> ExternalModelConfig {
        ExternalModelConfig(
            provider: provider,
            model: defaults.string(forKey: Keys.model(provider)) ?? "",
            baseURL: defaults.string(forKey: Keys.baseURL(provider)) ?? "",
            apiKey: secrets.secret(for: Keys.apiKey(provider)) ?? ""
        )
    }

    /// Saves a provider's settings. An empty key removes the stored key.
    public func save(_ config: ExternalModelConfig) throws {
        let provider = config.provider
        try secrets.setSecret(config.trimmedKey.isEmpty ? nil : config.trimmedKey, for: Keys.apiKey(provider))
        defaults.set(config.trimmedModel, forKey: Keys.model(provider))
        defaults.set(config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.baseURL(provider))
    }

    /// The configuration chats should use right now, or nil when the switch is off or the selected
    /// provider is not fully set up. `nil` means "use the on-device model".
    public func activeConfig() -> ExternalModelConfig? {
        guard isEnabled else { return nil }
        let config = config(for: selectedProvider)
        return config.isReady ? config : nil
    }

    /// Removes every saved key and setting, and switches back to the on-device model.
    public func reset() {
        isEnabled = false
        for provider in ExternalProvider.allCases {
            try? secrets.setSecret(nil, for: Keys.apiKey(provider))
            defaults.removeObject(forKey: Keys.model(provider))
            defaults.removeObject(forKey: Keys.baseURL(provider))
        }
        defaults.removeObject(forKey: Keys.provider)
    }
}
