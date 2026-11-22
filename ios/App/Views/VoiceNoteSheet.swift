import SwiftUI
import LLMKit
import RAGKit

/// Review a structured voice note before saving it into the Voice notes RAG pack.
struct VoiceNoteSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let transcript: String
    var onSaved: (DocumentRecord) -> Void

    @State private var note: StructuredVoiceNote
    @State private var saving = false
    @State private var error: String?

    init(transcript: String, onSaved: @escaping (DocumentRecord) -> Void) {
        self.transcript = transcript
        self.onSaved = onSaved
        _note = State(initialValue: VoiceNoteStructurer.structure(transcript))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: noteTitle)
                }
                Section("Note") {
                    TextEditor(text: noteBody)
                        .frame(minHeight: 160)
                }
                Section("Pack") {
                    Text(note.pack)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Save voice note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || note.title.isEmpty || note.body.isEmpty)
                }
            }
            .task { await polish() }
        }
    }

    private var noteTitle: Binding<String> {
        Binding(get: { note.title }, set: { note = StructuredVoiceNote(title: $0, body: note.body, tags: note.tags, pack: note.pack) })
    }

    private var noteBody: Binding<String> {
        Binding(get: { note.body }, set: { note = StructuredVoiceNote(title: note.title, body: $0, tags: note.tags, pack: note.pack) })
    }

    private func polish() async {
        let request = VoiceNoteStructurer().polishRequest(transcript: transcript)
        if let raw = try? await environment.activeEngine().respond(request) {
            note = VoiceNoteStructurer.parsePolished(raw, fallback: transcript)
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        if let record = await environment.importText(
            title: note.documentTitle,
            text: note.documentText,
            autoDismiss: true
        ) {
            onSaved(record)
            dismiss()
        } else {
            error = "Could not save the note."
        }
    }
}
