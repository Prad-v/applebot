import SwiftUI
import LLMKit

/// Settings → Behavioral patterns: routines, interests, stress learned on-device.
struct BehavioralProfileView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var store = environment.behavior
        let profile = store.profile

        Form {
            Section {
                Toggle("Use behavioral patterns in chat", isOn: Binding(
                    get: { store.isEnabled },
                    set: { store.isEnabled = $0 }
                ))
                .accessibilityIdentifier("behavioral-enabled")
            } footer: {
                Text("Applebot summarizes sleep, activity, calendar windows, search topics, stress tone, and spending hints on this iPhone. Nothing is uploaded. This is a prompt card — not a cloud fine-tune.")
            }

            if profile.hasSummary {
                Section("Routines") {
                    if let sleep = profile.typicalSleepHours {
                        LabeledContent("Typical sleep", value: String(format: "%.1f h / night", sleep))
                    }
                    if let exercise = profile.exerciseDaysPerWeek {
                        LabeledContent("Exercise", value: String(format: "%.1f days / week", exercise))
                    }
                    if let steps = profile.typicalSteps {
                        LabeledContent("Typical steps", value: String(format: "%.0f / day", steps))
                    }
                    if let start = profile.workdayStartHour, let end = profile.workdayEndHour {
                        LabeledContent(
                            "Calendar work window",
                            value: String(format: "%02d:00–%02d:00", start, end)
                        )
                    } else if let start = profile.workdayStartHour {
                        LabeledContent("First meeting ~", value: String(format: "%02d:00", start))
                    }
                    if profile.sampleDays > 0 {
                        LabeledContent("Sample days", value: "\(profile.sampleDays)")
                    }
                }

                if !profile.topInterests.isEmpty {
                    Section("Often asks about") {
                        ForEach(profile.topInterests) { interest in
                            LabeledContent(interest.topic.displayName, value: "\(interest.count)")
                        }
                    }
                }

                if let travel = profile.travelAffinity, travel >= 0.35 {
                    Section("Travel") {
                        LabeledContent(
                            "Interest",
                            value: travel >= 0.65 ? "High" : "Moderate"
                        )
                    }
                }

                if let stress = profile.stressNote {
                    Section("Stress pattern") {
                        Text(stress)
                    }
                }

                if let spending = profile.spendingNote {
                    Section("Spending hints") {
                        Text(spending)
                    }
                }
            } else {
                Section {
                    Text("Keep chatting and connect Health / Calendar. Patterns appear after a few days of sleep, activity, or topic signals.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Refresh from Health & Calendar", action: refresh)
                    .accessibilityIdentifier("behavioral-refresh")
                Button("Clear behavioral data", role: .destructive) {
                    store.clear()
                }
            } footer: {
                Text("Refresh pulls the last Health week trend and today’s calendar window. Chat topics update automatically after each reply.")
            }
        }
        .navigationTitle("Behavioral patterns")
        .task {
            await environment.refreshBehavioralProfile()
        }
    }

    private func refresh() {
        Task {
            await environment.refreshBehavioralProfile()
        }
    }
}
