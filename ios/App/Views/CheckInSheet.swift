import SwiftUI
import LLMKit

struct CheckInSheet: View {
    let suggestion: CheckInSuggestion
    var onAccept: (String) -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("A gentle check-in")
                    .font(.title2.bold())
                Text(suggestion.prompt)
                    .font(.body)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Let's talk") { onAccept(suggestion.prompt) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct AutomationDueSheet: View {
    let recipe: AutomationRecipe
    var onRun: (AutomationRecipe) -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(recipe.title)
                    .font(.title2.bold())
                Text(recipe.cadence.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(recipe.prompt)
                    .font(.body)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .navigationTitle("Automation due")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { onRun(recipe) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
