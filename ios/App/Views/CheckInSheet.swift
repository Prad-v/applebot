import SwiftUI
import LLMKit

struct CheckInSheet: View {
    let suggestion: CheckInSuggestion
    var onAccept: (String) -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ApplebotTheme.spaceM) {
                Text("Check-in")
                    .font(ApplebotTheme.caption().weight(.semibold))
                    .foregroundStyle(ApplebotTheme.tertiaryInk)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text("A gentle check-in")
                    .font(ApplebotTheme.display(24))
                    .foregroundStyle(ApplebotTheme.ink)
                Text(suggestion.prompt)
                    .font(ApplebotTheme.body())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
                    .lineSpacing(2)

                Spacer()

                ApplebotPrimaryButton(title: "Let's talk") {
                    onAccept(suggestion.prompt)
                }
                ApplebotSecondaryButton(title: "Not now", action: onDismiss)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ApplebotTheme.spaceM)
            .applebotCanvas()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now", action: onDismiss)
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
            VStack(alignment: .leading, spacing: ApplebotTheme.spaceM) {
                Text(recipe.cadence.displayName)
                    .font(ApplebotTheme.caption().weight(.semibold))
                    .foregroundStyle(ApplebotTheme.tertiaryInk)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(recipe.title)
                    .font(ApplebotTheme.display(24))
                    .foregroundStyle(ApplebotTheme.ink)
                Text(recipe.prompt)
                    .font(ApplebotTheme.body())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
                    .lineSpacing(2)

                Spacer()

                ApplebotPrimaryButton(title: "Run") {
                    onRun(recipe)
                }
                ApplebotSecondaryButton(title: "Skip", action: onDismiss)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ApplebotTheme.spaceM)
            .applebotCanvas()
            .navigationTitle("Automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip", action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
