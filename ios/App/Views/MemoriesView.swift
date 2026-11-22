import SwiftUI
import LLMKit

/// Settings → What Applebot remembers.
struct MemoriesView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var memory = environment.memory

        List {
            Section {
                Toggle("Remember across chats", isOn: $memory.isEnabled)
                    .accessibilityIdentifier("memory-enabled")
            } footer: {
                Text("When on, Applebot keeps short facts from your chats on this iPhone and uses them in future conversations. Preferences wait for your confirmation in Your profile. Nothing is uploaded.")
            }

            if memory.facts.isEmpty {
                Section {
                    Text(memory.isEnabled
                         ? "Nothing remembered yet. As you chat, durable facts like names and upcoming events can appear here."
                         : "Memory is off.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Remembered (\(memory.facts.count))") {
                    ForEach(memory.facts) { fact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fact.text)
                            HStack(spacing: 8) {
                                Text(fact.category.displayName)
                                if let expires = fact.expiresAt {
                                    Text("· expires \(expires.formatted(date: .abbreviated, time: .omitted))")
                                }
                                if fact.pinned {
                                    Image(systemName: "pin.fill")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", role: .destructive) {
                                memory.delete(fact)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button(fact.pinned ? "Unpin" : "Pin") {
                                memory.togglePin(fact)
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
        }
        .navigationTitle("Memories")
        .onAppear {
            memory.reload()
            memory.purgeExpired()
        }
    }
}
