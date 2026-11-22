import SwiftUI
import LLMKit

/// Settings → Write like me: style card for on-device rewrites.
struct StyleCardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var sample0 = ""
    @State private var sample1 = ""
    @State private var sample2 = ""
    @State private var traits = ""

    var body: some View {
        @Bindable var store = environment.styleCard

        Form {
            Section {
                Toggle("Enable style rewrite", isOn: Binding(
                    get: { store.card.isEnabled },
                    set: { enabled in
                        store.card = StyleCard(
                            samples: [sample0, sample1, sample2],
                            traits: traits,
                            isEnabled: enabled
                        )
                    }
                ))
                .accessibilityIdentifier("style-card-enabled")
            } footer: {
                Text("When on, messages like “rewrite this: …” are rewritten in your voice on this iPhone. No cloud fine-tune.")
            }

            Section {
                TextField("Traits (optional)", text: $traits, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Sample 1", text: $sample0, axis: .vertical)
                    .lineLimit(3...6)
                TextField("Sample 2", text: $sample1, axis: .vertical)
                    .lineLimit(3...6)
                TextField("Sample 3", text: $sample2, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("Your writing samples")
            } footer: {
                Text("Paste a few short emails or notes that sound like you. Samples stay on this iPhone.")
            }

            Section {
                Button("Save style card") { save() }
                    .accessibilityIdentifier("style-card-save")
            }
        }
        .navigationTitle("Write like me")
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    private func load() {
        let card = environment.styleCard.card
        traits = card.traits
        sample0 = card.samples.count > 0 ? card.samples[0] : ""
        sample1 = card.samples.count > 1 ? card.samples[1] : ""
        sample2 = card.samples.count > 2 ? card.samples[2] : ""
    }

    private func save() {
        let enabled = environment.styleCard.card.isEnabled
        environment.styleCard.card = StyleCard(
            samples: [sample0, sample1, sample2],
            traits: traits,
            isEnabled: enabled
        )
    }
}
