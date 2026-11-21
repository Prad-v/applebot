import SwiftUI
import RAGKit

struct DocumentsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showImporter = false
    @State private var showPaste = false

    var body: some View {
        NavigationStack {
            List {
                if let error = environment.startupError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }

                if !environment.imports.isEmpty {
                    Section("Importing") {
                        ForEach(environment.imports) { job in ImportRow(job: job) }
                        if environment.imports.contains(where: { $0.state != .running }) {
                            Button("Clear finished") { environment.dismissFinishedImports() }
                        }
                    }
                }

                Section {
                    if environment.documents.isEmpty {
                        ContentUnavailableView {
                            Label("No documents yet", systemImage: "doc.badge.plus")
                        } description: {
                            Text("Add PDFs, notes, or photos of documents. They are read and indexed on this iPhone, never uploaded.")
                        } actions: {
                            Button("Add documents") { showImporter = true }
                                .buttonStyle(.borderedProminent)
                        }
                        .listRowBackground(Color.clear)
                    }
                    ForEach(environment.documents) { document in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.title).font(.headline)
                            Text("\(document.chunkCount) passages · added \(document.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await environment.remove(document: document) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    if !environment.documents.isEmpty {
                        Text("\(environment.documents.count) documents · \(environment.chunkCount) passages")
                    }
                } footer: {
                    if !environment.documents.isEmpty {
                        Text("Originals are not copied into the app. Only extracted text and search vectors are stored, encrypted at rest.")
                    }
                }
            }
            .navigationTitle("Documents")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Import files", systemImage: "folder") { showImporter = true }
                        Button("Paste text", systemImage: "doc.on.clipboard") { showPaste = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-document")
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: DocumentTypes.allowed,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { environment.importFiles(urls) }
            }
            .sheet(isPresented: $showPaste) { PasteTextSheet() }
        }
    }
}

struct ImportRow: View {
    let job: ImportJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.name).font(.subheadline.bold()).lineLimit(1)
            switch job.state {
            case .running:
                ProgressView(value: job.progress)
                Text(job.progress == 0 ? "Reading…" : "Indexing \(Int(job.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            case .done(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
}
