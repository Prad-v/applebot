import SwiftUI
import RAGKit

struct DocumentsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showImporter = false
    @State private var showPaste = false
    @State private var packFilter: String? = nil // nil = all; "" = unfiled
    @State private var newPackName = ""
    @State private var showNewPack = false
    @State private var assigning: DocumentRecord?

    private var filtered: [DocumentRecord] {
        switch packFilter {
        case nil: return environment.documents
        case "": return DocumentPack.filter(environment.documents, pack: "")
        case let name?: return DocumentPack.filter(environment.documents, pack: name)
        }
    }

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
                    Picker("Pack", selection: $packFilter) {
                        Text("All").tag(String?.none)
                        Text(DocumentPack.unfiledLabel).tag(Optional(""))
                        ForEach(environment.documentPacks, id: \.self) { pack in
                            Text(pack).tag(Optional(pack))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("pack-filter")
                    Button("New pack…") { showNewPack = true }
                } header: {
                    Text("Packs")
                } footer: {
                    Text("Group documents into packs like Work, Health, or Voice notes. Search in a chat can still use all documents or attachments.")
                }

                Section {
                    if filtered.isEmpty {
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
                    ForEach(filtered) { document in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.displayTitle).font(.headline)
                            HStack(spacing: 6) {
                                if let pack = DocumentPack.pack(of: document) {
                                    Text(pack)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                }
                                Text("\(document.chunkCount) passages · \(document.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await environment.remove(document: document) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Pack") { assigning = document }
                                .tint(.indigo)
                        }
                        .contextMenu {
                            Button("Move to pack…") { assigning = document }
                            Button("Unfiled") {
                                Task { await environment.setDocumentPack(document, pack: nil) }
                            }
                        }
                    }
                } header: {
                    if !environment.documents.isEmpty {
                        Text("\(filtered.count) of \(environment.documents.count) · \(environment.chunkCount) passages")
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
            .alert("New pack", isPresented: $showNewPack) {
                TextField("Pack name", text: $newPackName)
                Button("Create") {
                    let name = newPackName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { packFilter = name }
                    newPackName = ""
                }
                Button("Cancel", role: .cancel) { newPackName = "" }
            } message: {
                Text("Create a pack, then move documents into it with swipe or long-press.")
            }
            .confirmationDialog("Move to pack", isPresented: Binding(
                get: { assigning != nil },
                set: { if !$0 { assigning = nil } }
            ), titleVisibility: .visible) {
                ForEach(environment.documentPacks, id: \.self) { pack in
                    Button(pack) {
                        if let doc = assigning {
                            Task { await environment.setDocumentPack(doc, pack: pack) }
                        }
                        assigning = nil
                    }
                }
                if let pending = packFilter, !pending.isEmpty, !environment.documentPacks.contains(pending) {
                    Button(pending) {
                        if let doc = assigning {
                            Task { await environment.setDocumentPack(doc, pack: pending) }
                        }
                        assigning = nil
                    }
                }
                Button("Unfiled") {
                    if let doc = assigning {
                        Task { await environment.setDocumentPack(doc, pack: nil) }
                    }
                    assigning = nil
                }
                Button("Cancel", role: .cancel) { assigning = nil }
            }
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
