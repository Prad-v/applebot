import SwiftUI
import LLMKit

/// Settings → Your profile: structured identity + confirmed preferences.
struct PersonalProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var name: String = ""
    @State private var city: String = ""
    @State private var rolesText: String = ""
    @State private var boundaryDraft: String = ""

    var body: some View {
        @Bindable var profileStore = environment.profile
        let profile = profileStore.profile

        Form {
            Section {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .accessibilityIdentifier("profile-name")
                TextField("City", text: $city)
                    .accessibilityIdentifier("profile-city")
                TextField("Roles (comma-separated)", text: $rolesText)
                    .accessibilityIdentifier("profile-roles")
                Picker("Reply style", selection: Binding(
                    get: { profile.replyStyle },
                    set: { profileStore.setReplyStyle($0) }
                )) {
                    ForEach(ReplyStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            } header: {
                Text("About you")
            } footer: {
                Text("Kept on this iPhone and injected into chats as a compact profile so memory facts stay within budget.")
            }
            .onAppear(perform: load)
            .onDisappear(perform: saveBasics)

            if !profile.pendingPrefs.isEmpty {
                Section {
                    ForEach(profile.pendingPrefs) { pending in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pending.text)
                            HStack {
                                Button("Keep") { profileStore.confirmPreference(id: pending.id) }
                                    .buttonStyle(.borderedProminent)
                                Button("Dismiss", role: .destructive) {
                                    profileStore.dismissPreference(id: pending.id)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Confirm preferences")
                } footer: {
                    Text("Applebot noticed these while chatting. Confirm to use them in every conversation.")
                }
            }

            if !profile.confirmedPrefs.isEmpty {
                Section("Confirmed preferences") {
                    ForEach(profile.confirmedPrefs, id: \.self) { pref in
                        Text(pref)
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    profileStore.removeConfirmedPref(pref)
                                }
                            }
                    }
                }
            }

            Section {
                ForEach(profile.boundaries, id: \.self) { boundary in
                    Text(boundary)
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                profileStore.setBoundaries(profile.boundaries.filter { $0 != boundary })
                            }
                        }
                }
                HStack {
                    TextField("Add a boundary (e.g. no work talk after 9pm)", text: $boundaryDraft)
                    Button("Add") {
                        let trimmed = boundaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        profileStore.setBoundaries(profile.boundaries + [trimmed])
                        boundaryDraft = ""
                    }
                    .disabled(boundaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Boundaries")
            }
        }
        .navigationTitle("Your profile")
    }

    private func load() {
        let profile = environment.profile.profile
        name = profile.displayName ?? ""
        city = profile.city ?? ""
        rolesText = profile.roles.joined(separator: ", ")
    }

    private func saveBasics() {
        environment.profile.setDisplayName(name)
        environment.profile.setCity(city)
        let roles = rolesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        environment.profile.setRoles(roles)
    }
}
