import SwiftUI
import LLMKit

struct FamilyProfilesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var newName = ""
    @State private var showAdd = false
    @State private var renameTarget: FamilyProfile?
    @State private var renameText = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(environment.family.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.headline)
                            if profile.id == environment.family.activeID {
                                Text("Active").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if profile.id != environment.family.activeID {
                            Button("Switch") {
                                Task {
                                    let ok = await environment.switchProfile(to: profile.id)
                                    if !ok { error = "Could not switch profiles. Unlock with Face ID / passcode and try again." }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .swipeActions {
                        if environment.family.profiles.count > 1 {
                            Button("Delete", role: .destructive) {
                                _ = environment.family.remove(id: profile.id)
                                if environment.family.activeID != profile.id {
                                    // already switched by remove if needed
                                }
                                Task { _ = await environment.switchProfile(to: environment.family.activeID) }
                            }
                        }
                    }
                    .contextMenu {
                        Button("Rename…") {
                            renameTarget = profile
                            renameText = profile.name
                        }
                        Toggle(
                            "Require Face ID to switch here",
                            isOn: Binding(
                                get: { profile.requiresAuthToSwitch },
                                set: { environment.family.setRequiresAuth(id: profile.id, enabled: $0) }
                            )
                        )
                    }
                }
            } header: {
                Text("Profiles on this iPhone")
            } footer: {
                Text("Each profile keeps its own memories, preferences, style card, automations, and document ownership. Switching can require Face ID.")
            }

            Section {
                Button("Add profile…") { showAdd = true }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Family profiles")
        .alert("Add profile", isPresented: $showAdd) {
            TextField("Name", text: $newName)
            Button("Add") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    let created = environment.family.add(name: name)
                    Task { _ = await environment.switchProfile(to: created.id) }
                }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let target = renameTarget {
                    environment.family.rename(id: target.id, name: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }
}
