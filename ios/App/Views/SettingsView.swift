import SwiftUI
import SwiftData
import LLMKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppEnvironment.Keys.retrievalLimit) private var retrievalLimit = 4
    @AppStorage(AppEnvironment.Keys.chatTone) private var toneRaw = ChatTone.neutral.rawValue
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var environment = environment

        NavigationStack {
            Form {
                Section("On-device model") {
                    HStack(spacing: 10) {
                        Image(systemName: environment.availability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(environment.availability.isAvailable ? .green : .orange)
                        Text(environment.availability.message)
                    }
                    LabeledContent("Model", value: "Apple Intelligence (on-device)")
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
                    Text("Removes everything Applebot stores on this device and signs out of connected accounts. This cannot be undone.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    Text("Applebot runs Apple's on-device language model. Your messages and documents never leave this iPhone. The only exception is a connector you switch on, which talks directly to its own service (for example Gmail) and nowhere else.")
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
                Text("All chats and the document library will be erased from this device.")
            }
        }
    }

    /// "Not used" until the user switches on a connector that has an online account.
    private var networkSummary: String {
        environment.connectors.rows.contains { $0.isActive && $0.hasAccount }
            ? "Only for connectors you turned on"
            : "Not used"
    }

    private var connectorsSummary: String {
        let active = environment.connectors.activeNames
        return active.isEmpty ? "None on" : active.joined(separator: ", ")
    }
}
