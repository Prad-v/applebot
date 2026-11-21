import SwiftUI
import RAGKit

/// Add a note by pasting text. Used from the Documents tab and from a chat's "+" menu.
struct PasteTextSheet: View {
    /// Called with the library record once the text is indexed (used to attach it to a chat).
    var onAdded: (@MainActor (DocumentRecord) -> Void)?
    /// Hide the progress row shortly after success (chat attach flow).
    var autoDismiss = false

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") { TextField("e.g. Meeting notes", text: $title) }
                Section("Text") {
                    TextEditor(text: $text).frame(minHeight: 220)
                }
            }
            .navigationTitle("Paste text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let body = text
                        let environment = environment
                        let onAdded = onAdded
                        let autoDismiss = autoDismiss
                        dismiss()
                        Task {
                            let record = await environment.importText(
                                title: name.isEmpty ? "Pasted note" : name, text: body, autoDismiss: autoDismiss
                            )
                            if let record { onAdded?(record) }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
