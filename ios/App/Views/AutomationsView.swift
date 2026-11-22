import SwiftUI
import LLMKit

struct AutomationsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var draftTitle = ""
    @State private var draftPrompt = ""
    @State private var draftCadence: AutomationCadence = .weeklySunday
    @State private var showAdd = false

    var body: some View {
        List {
            Section {
                ForEach(environment.automations.recipes) { recipe in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(recipe.title).font(.headline)
                            Spacer()
                            Toggle(
                                "On",
                                isOn: Binding(
                                    get: { recipe.isEnabled },
                                    set: { environment.automations.setEnabled(recipe.id, enabled: $0) }
                                )
                            )
                            .labelsHidden()
                        }
                        Text(recipe.cadence.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(recipe.prompt)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            environment.automations.delete(recipe.id)
                        }
                    }
                }
            } header: {
                Text("Local recipes")
            } footer: {
                Text("When a recipe is due, Applebot offers it on unlock. Nothing runs until you confirm. No cloud scheduling.")
            }

            Section {
                Button("Add recipe…") { showAdd = true }
                Button("Restore templates") {
                    for template in AutomationRecipe.templates {
                        if !environment.automations.recipes.contains(where: { $0.title == template.title }) {
                            environment.automations.upsert(template)
                        }
                    }
                }
            }
        }
        .navigationTitle("Automations")
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                Form {
                    TextField("Title", text: $draftTitle)
                    Picker("When", selection: $draftCadence) {
                        ForEach(AutomationCadence.allCases) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    TextField("Prompt", text: $draftPrompt, axis: .vertical)
                        .lineLimit(4...8)
                }
                .navigationTitle("New recipe")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let recipe = AutomationRecipe(
                                title: draftTitle,
                                prompt: draftPrompt,
                                cadence: draftCadence
                            )
                            environment.automations.upsert(recipe)
                            draftTitle = ""
                            draftPrompt = ""
                            showAdd = false
                        }
                        .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                  || draftPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
