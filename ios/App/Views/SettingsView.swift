import SwiftUI
import SwiftData
import LLMKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppEnvironment.Keys.retrievalLimit) private var retrievalLimit = 4
    @AppStorage(AppEnvironment.Keys.chatTone) private var toneRaw = ChatTone.productDefault.rawValue
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var environment = environment

        NavigationStack {
            Form {
                Section("Model") {
                    HStack(spacing: 10) {
                        Image(systemName: environment.availability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(environment.availability.isAvailable ? .green : .orange)
                        Text(environment.availability.isAvailable
                             ? environment.modelSummary
                             : environment.availability.message)
                    }
                    NavigationLink {
                        ExternalModelSettingsView()
                    } label: {
                        LabeledContent(
                            "External model",
                            value: environment.externalModelEnabled
                                ? (environment.isUsingExternalModel ? "On" : "Needs setup")
                                : "Off"
                        )
                    }
                    .accessibilityIdentifier("external-model-link")
                    LabeledContent("Network", value: networkSummary)
                }

                Section {
                    NavigationLink {
                        ConnectorsView()
                    } label: {
                        LabeledContent("Connectors", value: connectorsSummary)
                    }
                    .accessibilityIdentifier("connectors-link")
                } header: {
                    Text("Connected services")
                } footer: {
                    Text("Let Applebot use Gmail and your calendar when you ask. It asks before it changes anything.")
                }

                Section {
                    Picker("Style", selection: $toneRaw) {
                        ForEach(ChatTone.allCases) { tone in
                            Text(tone.displayName).tag(tone.rawValue)
                        }
                    }
                    .accessibilityIdentifier("tone-picker")
                } header: {
                    Text("Conversation style")
                } footer: {
                    Text((ChatTone(rawValue: toneRaw) ?? .neutral).summary
                         + " Applebot reads the mood of your message on this iPhone to match its tone. It is not a therapist.")
                }

                Section {
                    NavigationLink {
                        MemoriesView()
                    } label: {
                        LabeledContent(
                            "What Applebot remembers",
                            value: environment.memory.isEnabled
                                ? (environment.memory.facts.isEmpty ? "On" : "\(environment.memory.facts.count)")
                                : "Off"
                        )
                    }
                    .accessibilityIdentifier("memories-link")
                } header: {
                    Text("Memory")
                } footer: {
                    Text("Facts stay on this iPhone and can be used in every chat. Open the list to pin or delete them.")
                }

                Section {
                    Toggle("Speak replies", isOn: Bindable(environment.voice).autoSpeak)
                        .accessibilityIdentifier("voice-auto-speak")
                    Toggle("Hands-free conversation", isOn: Bindable(environment.voice).handsFree)
                        .disabled(!environment.voice.autoSpeak)
                        .accessibilityIdentifier("voice-hands-free")
                    LabeledContent(
                        "On-device speech",
                        value: environment.voice.onDeviceRecognitionAvailable ? "Available" : "Unavailable"
                    )
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Speech recognition and spoken replies stay on this iPhone. If on-device recognition is unavailable for your language, the mic stays off so audio is never sent to Apple's servers. Hands-free listens again after each spoken reply.")
                }

                Section {
                    Stepper("Passages per answer: \(retrievalLimit)", value: $retrievalLimit, in: 2...6)
                } header: {
                    Text("Documents")
                } footer: {
                    Text("More passages can improve recall, but the on-device model has a small context window, so long passages may be trimmed.")
                }

                Section {
                    LabeledContent("Documents", value: "\(environment.documents.count)")
                    LabeledContent("Passages", value: "\(environment.chunkCount)")
                    LabeledContent("Embeddings", value: environment.embedderIdentifier)
                } header: {
                    Text("Library")
                }

                Section {
                    Toggle("Require Face ID / passcode", isOn: $environment.lockEnabled)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Locks the app whenever it goes to the background. Data is also encrypted at rest by iOS.")
                }

                Section {
                    Button("Delete all chats and documents", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Removes chats, documents, memories, and signs out of connected accounts. This cannot be undone.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    Text(aboutText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete everything?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive) {
                    Task { await environment.deleteAllData(modelContext: modelContext) }
                }
            } message: {
                Text("All chats, documents, and remembered facts will be erased from this device.")
            }
        }
    }

    /// "Not used" until the user switches on a connector or an external model that talks online.
    private var networkSummary: String {
        if environment.isUsingExternalModel {
            return "External model (+ connectors you turned on)"
        }
        return environment.connectors.rows.contains { $0.isActive && $0.usesNetwork }
            ? "Only for connectors you turned on"
            : "Not used"
    }

    private var connectorsSummary: String {
        let active = environment.connectors.activeNames
        return active.isEmpty ? "None on" : active.joined(separator: ", ")
    }

    private var aboutText: String {
        if environment.isUsingExternalModel {
            return "Chats are sent to the external model you configured (API key stays in the Keychain on this iPhone). Documents still stay on device for search; only the text needed for each answer is included in the prompt to the provider. Connectors you switch on talk directly to their own services."
        }
        return "Applebot runs Apple's on-device language model by default. Your messages and documents never leave this iPhone. The only exceptions are a connector you switch on, or an external model you enable in Settings, each of which talks directly to its own service."
    }
}
