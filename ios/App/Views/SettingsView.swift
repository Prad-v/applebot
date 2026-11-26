import SwiftUI
import SwiftData
import LLMKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeController.self) private var theme
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppEnvironment.Keys.retrievalLimit) private var retrievalLimit = 4
    @AppStorage(AppEnvironment.Keys.chatTone) private var toneRaw = ChatTone.productDefault.rawValue
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var environment = environment

        NavigationStack {
            List {
                Section {
                    youHero
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section {
                    NavigationLink {
                        ThemeSettingsView()
                    } label: {
                        LabeledContent("Theme", value: theme.selection.displayName)
                    }
                    .accessibilityIdentifier("theme-link")
                } header: {
                    Text("Appearance").applebotSectionTitle()
                } footer: {
                    Text("Pick a colour theme with text contrast you find comfortable. System follows Light/Dark on this iPhone.")
                        .font(ApplebotTheme.caption())
                        .foregroundStyle(ApplebotTheme.secondaryInk)
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: environment.availability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(environment.availability.isAvailable ? .green : ApplebotTheme.warning)
                        Text(environment.availability.isAvailable
                             ? environment.modelSummary
                             : environment.availability.message)
                            .font(ApplebotTheme.footnote())
                            .foregroundStyle(ApplebotTheme.ink)
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
                } header: {
                    Text("Model").applebotSectionTitle()
                }

                Section {
                    NavigationLink {
                        ConnectorsView()
                    } label: {
                        LabeledContent("Connectors", value: connectorsSummary)
                    }
                    .accessibilityIdentifier("connectors-link")
                } header: {
                    Text("Connected services").applebotSectionTitle()
                } footer: {
                    Text("Let Applebot use Gmail, Calendar, and Reminders when you ask. It asks before it changes anything.")
                        .font(ApplebotTheme.caption())
                }

                Section {
                    Picker("Style", selection: $toneRaw) {
                        ForEach(ChatTone.allCases) { tone in
                            Text(tone.displayName).tag(tone.rawValue)
                        }
                    }
                    .accessibilityIdentifier("tone-picker")
                } header: {
                    Text("Conversation style").applebotSectionTitle()
                } footer: {
                    Text((ChatTone(rawValue: toneRaw) ?? .neutral).summary
                         + " Applebot reads the mood of your message on this iPhone to match its tone. It is not a therapist.")
                        .font(ApplebotTheme.caption())
                }

                Section {
                    NavigationLink {
                        FamilyProfilesView()
                    } label: {
                        LabeledContent("Family profile", value: environment.family.active.name)
                    }
                    .accessibilityIdentifier("family-profiles-link")

                    NavigationLink {
                        PersonalProfileView()
                    } label: {
                        LabeledContent(
                            "Your profile",
                            value: environment.profile.profile.displayName
                                ?? (environment.profile.profile.pendingPrefs.isEmpty ? "Set up" : "\(environment.profile.profile.pendingPrefs.count) to confirm")
                        )
                    }
                    .accessibilityIdentifier("profile-link")

                    NavigationLink {
                        BehavioralProfileView()
                    } label: {
                        LabeledContent(
                            "Behavioral patterns",
                            value: environment.behavior.summaryLine
                        )
                    }
                    .accessibilityIdentifier("behavioral-link")

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

                    Toggle("Morning brief on unlock", isOn: Bindable(environment.dailyBrief).isEnabled)
                        .accessibilityIdentifier("daily-brief-enabled")

                    Toggle("Gentle check-ins", isOn: Bindable(environment.checkIns).isEnabled)
                        .accessibilityIdentifier("check-ins-enabled")

                    NavigationLink {
                        StyleCardView()
                    } label: {
                        LabeledContent(
                            "Write like me",
                            value: environment.styleCard.isReady ? "On" : "Off"
                        )
                    }
                    .accessibilityIdentifier("style-card-link")

                    NavigationLink {
                        AutomationsView()
                    } label: {
                        LabeledContent(
                            "Automations",
                            value: "\(environment.automations.recipes.filter(\.isEnabled).count) on"
                        )
                    }

                    NavigationLink {
                        PersonalVaultView()
                    } label: {
                        Text("Backup & restore")
                    }

                    LabeledContent(
                        "Retrieval tune",
                        value: String(
                            format: "v %.2f · k %.2f",
                            environment.retrievalTuner.weights.vectorWeight,
                            environment.retrievalTuner.weights.keywordWeight
                        )
                    )
                } header: {
                    Text("Personal").applebotSectionTitle()
                } footer: {
                    Text("Profile, behavioral patterns, memories, packs, check-ins, automations and backups stay on this iPhone.")
                        .font(ApplebotTheme.caption())
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
                    LabeledContent("Speech Recognition", value: environment.voice.speechAuthDescription)
                    LabeledContent("Microphone", value: environment.voice.micAuthDescription)
                    Button("Open iOS Settings for Applebot") {
                        environment.voice.openSystemSettings()
                    }
                } header: {
                    Text("Voice").applebotSectionTitle()
                } footer: {
                    Text("In a chat, tap the mic (left of Send) or open + → Speak…. Hands-free only reopens the mic after a voice turn, not after typed messages. On a real iPhone, recognition stays on-device only.")
                        .font(ApplebotTheme.caption())
                }
                .onAppear { environment.voice.refreshAuthDescriptions(); environment.voice.refreshOnDeviceAvailability() }

                Section {
                    Stepper("Passages per answer: \(retrievalLimit)", value: $retrievalLimit, in: 2...6)
                } header: {
                    Text("Library search").applebotSectionTitle()
                } footer: {
                    Text("More passages can improve recall, but the on-device model has a small context window.")
                        .font(ApplebotTheme.caption())
                }

                Section {
                    LabeledContent("Documents", value: "\(environment.documents.count)")
                    LabeledContent("Passages", value: "\(environment.chunkCount)")
                    LabeledContent("Embeddings", value: environment.embedderIdentifier)
                } header: {
                    Text("Library stats").applebotSectionTitle()
                }

                Section {
                    Toggle("Require Face ID / passcode", isOn: $environment.lockEnabled)
                } header: {
                    Text("Privacy").applebotSectionTitle()
                } footer: {
                    Text("Locks the app whenever it goes to the background. Data is also encrypted at rest by iOS.")
                        .font(ApplebotTheme.caption())
                }

                Section {
                    Button("Delete all chats and documents", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Removes chats, documents, memories, and signs out of connected accounts. This cannot be undone.")
                        .font(ApplebotTheme.caption())
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    Text(aboutText)
                        .font(ApplebotTheme.caption())
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About").applebotSectionTitle()
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .applebotCanvas()
            .navigationTitle("You")
            .confirmationDialog("Delete everything?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive) {
                    Task { await environment.deleteAllData(modelContext: modelContext) }
                }
            } message: {
                Text("All chats, documents, and remembered facts will be erased from this device.")
            }
        }
    }

    private var youHero: some View {
        HStack(spacing: 12) {
            Text(initials)
                .font(.system(.subheadline, design: .default).weight(.semibold))
                .foregroundStyle(ApplebotTheme.accent)
                .frame(width: 40, height: 40)
                .background(
                    Circle().strokeBorder(ApplebotTheme.accent.opacity(0.28), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(environment.profile.profile.displayName ?? environment.family.active.name)
                    .font(ApplebotTheme.title())
                    .foregroundStyle(ApplebotTheme.ink)
                Text(environment.isUsingExternalModel
                     ? "External model · messages leave this iPhone"
                     : "On-device · private by default")
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var initials: String {
        let name = environment.profile.profile.displayName ?? environment.family.active.name
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "A" : letters.joined().uppercased()
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
        return "Applebot runs Apple's on-device language model by default. Your messages and documents never leave this iPhone. The only exceptions are a connector you switch on, or an external model you enable in You, each of which talks directly to its own service."
    }
}
