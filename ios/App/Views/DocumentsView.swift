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
            Group {
                if environment.documents.isEmpty && environment.imports.isEmpty {
                    emptyLibrary
                } else {
                    libraryList
                }
            }
            .applebotCanvas()
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Import files", systemImage: "folder") { showImporter = true }
                        Button("Paste text", systemImage: "doc.on.clipboard") { showPaste = true }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(ApplebotTheme.accent)
                    }
                    .accessibilityLabel("Add")
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

    private var emptyLibrary: some View {
        ScrollView {
            VStack(spacing: ApplebotTheme.spaceL) {
                ApplebotHeroEmpty(
                    symbol: "books.vertical.fill",
                    title: "Your private library",
                    message: "Add PDFs, notes, or photos. They are read and indexed on this iPhone — never uploaded.",
                    primaryTitle: "Add documents",
                    primarySystemImage: "doc.badge.plus",
                    primaryAction: { showImporter = true },
                    showBrand: false
                )

                ApplebotSecondaryButton(title: "Paste text", systemImage: "doc.on.clipboard") {
                    showPaste = true
                }
                .frame(maxWidth: 280)
            }
            .padding(.bottom, ApplebotTheme.spaceXL)
        }
    }

    private var libraryList: some View {
        List {
            if let error = environment.startupError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ApplebotTheme.warning)
                }
            }

            if !environment.imports.isEmpty {
                Section {
                    ForEach(environment.imports) { job in ImportRow(job: job) }
                    if environment.imports.contains(where: { $0.state != .running }) {
                        Button("Clear finished") { environment.dismissFinishedImports() }
                    }
                } header: {
                    Text("Importing").applebotSectionTitle()
                }
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ApplebotPill(title: "All", systemImage: "square.grid.2x2", isSelected: packFilter == nil) {
                            packFilter = nil
                        }
                        ApplebotPill(title: DocumentPack.unfiledLabel, systemImage: "tray", isSelected: packFilter == "") {
                            packFilter = ""
                        }
                        ForEach(environment.documentPacks, id: \.self) { pack in
                            ApplebotPill(title: pack, systemImage: "folder", isSelected: packFilter == pack) {
                                packFilter = pack
                            }
                        }
                        ApplebotPill(title: "New pack", systemImage: "plus") {
                            showNewPack = true
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("pack-filter")
            } header: {
                Text("Packs").applebotSectionTitle()
            } footer: {
                Text("Group documents into packs like Work, Health, or Voice notes.")
                    .font(ApplebotTheme.caption())
            }

            Section {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing in this pack", systemImage: "doc.badge.plus")
                    } description: {
                        Text("Move documents here with swipe, or add new ones.")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(filtered) { document in
                    DocumentRowLite(document: document)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await environment.remove(document: document) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Pack") { assigning = document }
                                .tint(ApplebotTheme.accent)
                        }
                        .contextMenu {
                            Button("Move to pack…") { assigning = document }
                            Button("Unfiled") {
                                Task { await environment.setDocumentPack(document, pack: nil) }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                        .listRowBackground(Color.clear)
                }
            } header: {
                if !environment.documents.isEmpty {
                    Text("\(filtered.count) of \(environment.documents.count) · \(environment.chunkCount) passages")
                        .applebotSectionTitle()
                }
            } footer: {
                if !environment.documents.isEmpty {
                    Text("Originals are not copied into the app. Only extracted text and search vectors are stored, encrypted at rest.")
                        .font(ApplebotTheme.caption())
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct DocumentRowLite: View {
    let document: DocumentRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.displayTitle)
                .font(.system(.body, design: .default).weight(.medium))
                .foregroundStyle(ApplebotTheme.ink)
            HStack(spacing: 6) {
                if let pack = DocumentPack.pack(of: document) {
                    Text(pack)
                        .font(ApplebotTheme.caption().weight(.medium))
                        .foregroundStyle(ApplebotTheme.accent)
                }
                Text("\(document.chunkCount) passages · \(document.addedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(ApplebotTheme.tertiaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
                    .tint(ApplebotTheme.accent)
                Text(job.progress == 0 ? "Reading…" : "Indexing \(Int(job.progress * 100))%")
                    .font(ApplebotTheme.caption()).foregroundStyle(.secondary)
            case .done(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(ApplebotTheme.caption()).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(ApplebotTheme.caption()).foregroundStyle(ApplebotTheme.danger)
            }
        }
    }
}
