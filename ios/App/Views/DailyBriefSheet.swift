import SwiftUI
import LLMKit

/// Shown once per day on unlock / foreground when Daily Brief is enabled.
struct DailyBriefSheet: View {
    let brief: DailyBrief
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ApplebotTheme.spaceL) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Brief")
                            .font(ApplebotTheme.caption().weight(.semibold))
                            .foregroundStyle(ApplebotTheme.tertiaryInk)
                            .textCase(.uppercase)
                            .tracking(0.6)
                        Text(brief.greeting)
                            .font(ApplebotTheme.display(24))
                            .foregroundStyle(ApplebotTheme.ink)
                    }

                    briefBlock(title: "Today") {
                        if brief.agendaLines.isEmpty {
                            Text("Nothing on the calendar (or Calendar is off).")
                                .foregroundStyle(ApplebotTheme.secondaryInk)
                        } else {
                            ForEach(brief.agendaLines, id: \.self) { line in
                                Text(line)
                            }
                        }
                    }

                    if !brief.reminderLines.isEmpty {
                        briefBlock(title: "Reminders") {
                            ForEach(brief.reminderLines, id: \.self) { line in
                                Text(line)
                            }
                        }
                    }

                    if !brief.healthLines.isEmpty {
                        briefBlock(title: "Health") {
                            ForEach(brief.healthLines, id: \.self) { line in
                                Text(line)
                            }
                            Text("Not medical advice.")
                                .font(ApplebotTheme.caption())
                                .foregroundStyle(ApplebotTheme.tertiaryInk)
                        }
                    }

                    if !brief.marketLines.isEmpty {
                        briefBlock(title: "Markets") {
                            ForEach(brief.marketLines, id: \.self) { line in
                                Text(line)
                            }
                            Text("Quotes can be delayed. Not financial advice.")
                                .font(ApplebotTheme.caption())
                                .foregroundStyle(ApplebotTheme.tertiaryInk)
                        }
                    }

                    if !brief.openLoops.isEmpty {
                        briefBlock(title: "Open loops") {
                            ForEach(brief.openLoops, id: \.self) { loop in
                                Text(loop)
                            }
                        }
                    }

                    ApplebotPrimaryButton(title: "Got it", action: onDismiss)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ApplebotTheme.spaceM)
            }
            .applebotCanvas()
            .navigationTitle("Your brief")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func briefBlock(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ApplebotTheme.caption().weight(.semibold))
                .foregroundStyle(ApplebotTheme.tertiaryInk)
                .textCase(.uppercase)
                .tracking(0.6)
            content()
                .font(ApplebotTheme.body())
                .foregroundStyle(ApplebotTheme.ink)
        }
    }
}
