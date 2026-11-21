import SwiftUI
import LLMKit

/// Settings → External model: pick OpenAI or Anthropic, paste a key, and switch chats off the on-device model.
struct ExternalModelSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    @State private var provider: ExternalProvider = .openAI
    @State private var model = ""
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var showKey = false
    @State private var showAdvanced = false
    @State private var saveError: String?
    @State private var didLoad = false

    var body: some View {
        @Bindable var environment = environment
        Form {
            Section {
                Toggle("Use external model", isOn: Binding(
                    get: { environment.externalModelEnabled },
                    set: { environment.setExternalModelEnabled($0) }
                ))
                .accessibilityIdentifier("external-model-toggle")
            } footer: {
                Text(footerText)
            }

            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(ExternalProvider.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .accessibilityIdentifier("external-provider-picker")
                .onChange(of: provider) { _, newValue in
                    loadFields(for: newValue)
                    environment.selectExternalProvider(newValue)
                }
            } header: {
                Text("Provider")
            }

            Section {
                TextField("Model", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("external-model-field")
                if !provider.suggestedModels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(provider.suggestedModels, id: \.self) { name in
                                Button(name) { model = name }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Leave blank to use \(provider.defaultModel). Any model your account can call works.")
            }

            Section {
                HStack {
                    Group {
                        if showKey {
                            TextField("API key", text: $apiKey)
                        } else {
                            SecureField("API key", text: $apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .accessibilityIdentifier("external-api-key")

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(showKey ? "Hide API key" : "Show API key")
                }
                if let url = URL(string: provider.keysPage) {
                    Button("Get an API key") { openURL(url) }
                }
            } header: {
                Text("API key")
            } footer: {
                Text("Stored only in this iPhone's Keychain. It is never written to iCloud or backups of other devices.")
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("external-base-url")
                    Text("Default: \(provider.defaultBaseURL)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Use a custom base URL for an OpenAI-compatible proxy or a local server (for example Ollama on this Mac). Plain http is only allowed for localhost and local-network addresses.")
            }

            if let problem = draftConfig.problem, environment.externalModelEnabled {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }
        }
        .navigationTitle("External model")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            provider = environment.externalStore.selectedProvider
            loadFields(for: provider)
        }
        .onChange(of: model) { _, _ in persist() }
        .onChange(of: apiKey) { _, _ in persist() }
        .onChange(of: baseURL) { _, _ in persist() }
        .alert("Couldn't save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var draftConfig: ExternalModelConfig {
        ExternalModelConfig(provider: provider, model: model, baseURL: baseURL, apiKey: apiKey)
    }

    private var footerText: String {
        if environment.externalModelEnabled {
            if draftConfig.isReady {
                return "Chats use \(provider.displayName) (\(draftConfig.effectiveModel)). Your messages leave this iPhone for that provider. Turn the switch off to return to the on-device model."
            }
            return "The switch is on, but \(draftConfig.problem ?? "the provider is not ready"). Chats stay blocked until this is fixed, or turn the switch off to use the on-device model."
        }
        return "Off by default. When on, chats call the provider you configure below instead of Apple Intelligence on this iPhone."
    }

    private func loadFields(for provider: ExternalProvider) {
        let saved = environment.externalStore.config(for: provider)
        model = saved.model
        apiKey = saved.apiKey
        baseURL = saved.baseURL
    }

    private func persist() {
        do {
            try environment.saveExternalConfig(draftConfig)
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
