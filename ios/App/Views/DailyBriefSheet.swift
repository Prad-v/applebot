import SwiftUI
import LLMKit

/// Shown once per day on unlock / foreground when Daily Brief is enabled.
struct DailyBriefSheet: View {
    let brief: DailyBrief
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(brief.greeting)
                        .font(.title2.bold())

                    Group {
                        Text("Today")
                            .font(.headline)
                        if brief.agendaLines.isEmpty {
                            Text("Nothing on the calendar (or Calendar is off).")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(brief.agendaLines, id: \.self) { line in
                                Label(line, systemImage: "calendar")
                            }
                        }
                    }

                    if !brief.openLoops.isEmpty {
                        Group {
                            Text("Open loops")
                                .font(.headline)
                            ForEach(brief.openLoops, id: \.self) { loop in
                                Label(loop, systemImage: "circle.dashed")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
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
}
