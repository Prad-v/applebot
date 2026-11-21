import SwiftUI
import SwiftData
import PhotosUI
import LLMKit
import RAGKit

struct ChatView: View {
    @Bindable var conversation: Conversation
    /// Replace this chat with a brand new, empty one (provided by the navigation container).
    var onNewChat: () -> Void = {}

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext

    @State private var controller = ChatController()
    @State private var draft = ""
    @State private var inspected: ChatMessage?
    @State private var showScope = false
    @State private var showImporter = false
    @State private var showPhotos = false
    @State private var showPaste = false
    @State private var photoItems: [PhotosPickerItem] = []
    @FocusState private var inputFocused: Bool

    private var messages: [ChatMessage] {
        conversation.orderedMessages.filter { !$0.isError }
    }

    var body: some View {
        VStack(spacing: 0) {
            AvailabilityBanner()
            ConnectorNotice(conversation: conversation)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if messages.isEmpty {
                            EmptyChatHint(
                                useDocuments: conversation.useDocuments && !environment.documents.isEmpty,
                                tone: environment.chatTone
                            ) { prompt in
                                send(prompt)
                            }
                        }
                        ForEach(messages) { message in
                            MessageBubble(message: message) { inspected = message }
                                .id(message.id)
                        }
                        if controller.isResponding, messages.last?.role != .assistant || messages.last?.text.isEmpty == true {
                            TypingIndicator(status: controller.status)
                                .id("typing")
                        } else if let status = controller.status {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = controller.errorMessage {
                            ErrorRow(message: error) {
                                controller.retry(conversation: conversation, environment: environment, context: modelContext)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last?.text) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            inputBar
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.stop()
                    onNewChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(messages.isEmpty)
                .accessibilityIdentifier("new-chat-inline")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle(isOn: $conversation.useDocuments) {
                        Label("Use my documents", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(environment.documents.isEmpty)
                    Button {
                        showScope = true
                    } label: {
                        Label(scopeLabel, systemImage: "checklist")
                    }
                    .disabled(environment.documents.isEmpty || !conversation.useDocuments)
                } label: {
                    Image(systemName: conversation.useDocuments && !environment.documents.isEmpty
                          ? "doc.text.magnifyingglass" : "ellipsis.circle")
                }
                .accessibilityIdentifier("chat-options")
            }
        }
        .sheet(item: $inspected) { message in
            SourcesSheet(message: message)
        }
        .sheet(isPresented: $showScope) {
            DocumentScopeSheet(conversation: conversation)
        }
        .sheet(isPresented: $showPaste) {
            PasteTextSheet(onAdded: { attach([$0]) }, autoDismiss: true)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: DocumentTypes.allowed,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                environment.importFiles(urls, autoDismiss: true) { attach($0) }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 5, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await attachPhotos(items) }
        }
        .onAppear { pruneScope() }
        .onChange(of: environment.documents) { _, _ in pruneScope() }
        .onDisappear { controller.stop() }
    }

    private var scopeLabel: String {
        conversation.scopeIDs.isEmpty ? "Search all documents" : "Search \(conversation.scopeIDs.count) selected"
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            attachmentsStrip
            composer
        }
        .background(.bar)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachMenu

            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityIdentifier("message-field")
                .onSubmit { send(draft) }

            if controller.isResponding {
                Button {
                    controller.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 32))
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !environment.availability.isAvailable)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// "+" menu: bring documents into this conversation.
    private var attachMenu: some View {
        Menu {
            Button { showImporter = true } label: { Label("Files…", systemImage: "folder") }
            Button { showPhotos = true } label: { Label("Photos…", systemImage: "photo.on.rectangle") }
            Button { showPaste = true } label: { Label("Paste text…", systemImage: "doc.on.clipboard") }
            if !environment.documents.isEmpty {
                Divider()
                Button { showScope = true } label: { Label("From my library…", systemImage: "books.vertical") }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Attach documents")
        .accessibilityIdentifier("attach")
    }

    /// Import progress plus the documents this chat is searching.
    @ViewBuilder
    private var attachmentsStrip: some View {
        let jobs = Array(environment.imports.suffix(2))
        if !jobs.isEmpty || (conversation.useDocuments && !environment.documents.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(jobs) { job in
                    ImportRow(job: job)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if conversation.useDocuments, !environment.documents.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if conversation.scopeIDs.isEmpty {
                                AttachmentChip(
                                    title: "All documents (\(environment.documents.count))",
                                    systemImage: "books.vertical",
                                    onRemove: nil
                                ) { showScope = true }
                            } else {
                                ForEach(scopedDocuments) { document in
                                    AttachmentChip(title: document.title, systemImage: "doc.text") {
                                        conversation.scopeIDs = DocumentScope.removing(document.id, from: conversation.scopeIDs)
                                    } onTap: { showScope = true }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private var scopedDocuments: [DocumentRecord] {
        let ids = Set(conversation.scopeIDs)
        return environment.documents.filter { ids.contains($0.id) }
    }

    /// Attach freshly imported documents to this conversation and make sure it uses them.
    private func attach(_ records: [DocumentRecord]) {
        guard !records.isEmpty else { return }
        conversation.scopeIDs = DocumentScope.attaching(records.map(\.id), to: conversation.scopeIDs)
        conversation.useDocuments = true
    }

    private func pruneScope() {
        guard !conversation.scopeIDs.isEmpty else { return }
        let pruned = DocumentScope.pruned(conversation.scopeIDs, existing: Set(environment.documents.map(\.id)))
        if pruned != conversation.scopeIDs { conversation.scopeIDs = pruned }
    }

    /// Save picked photos to temporary files (so the OCR importer can read them), then attach.
    private func attachPhotos(_ items: [PhotosPickerItem]) async {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        var urls: [URL] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Photo \(stamp)-\(index + 1).jpg")
            if (try? data.write(to: url)) != nil { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        environment.importFiles(urls, autoDismiss: true) { records in
            attach(records)
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func send(_ text: String) {
        guard environment.availability.isAvailable else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        controller.send(trimmed, conversation: conversation, environment: environment, context: modelContext)
    }
}

// MARK: - Pieces

struct MessageBubble: View {
    let message: ChatMessage
    var onInspect: () -> Void

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            Text(Self.rendered(message.text))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .background(
                    isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemBackground)),
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    ShareLink(item: message.text)
                }

            if !isUser {
                footer
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var footer: some View {
        if !message.toolsUsed.isEmpty {
            Label(message.toolsUsed.joined(separator: " · "), systemImage: "link")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("tools-used")
        }
        if message.notFound {
            Label("Not found in your documents", systemImage: "questionmark.folder")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !message.sources.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(message.citedSources.isEmpty ? [] : message.citedSources) { source in
                        Button(action: onInspect) {
                            Label(source.label, systemImage: "doc.text")
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button(action: onInspect) {
                        Label("Why this answer?", systemImage: "magnifyingglass")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }

    /// Inline markdown (bold, italics, code, links) with whitespace preserved.
    static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A pill showing which documents a chat searches. Tap opens the scope sheet; the x removes it.
private struct AttachmentChip: View {
    let title: String
    let systemImage: String
    var onRemove: (() -> Void)?
    let onTap: () -> Void

    init(title: String, systemImage: String, onRemove: (() -> Void)? = nil, onTap: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.onRemove = onRemove
        self.onTap = onTap
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTap) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .lineLimit(1)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachment-chip")
    }
}

private struct TypingIndicator: View {
    let status: String?
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(status ?? "Thinking…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .accessibilityIdentifier("typing-indicator")
    }
}

private struct ErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.subheadline)
            Spacer(minLength: 0)
            Button("Retry", action: retry).font(.subheadline.bold())
        }
        .padding(12)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EmptyChatHint: View {
    let useDocuments: Bool
    var tone: ChatTone = .neutral
    let pick: (String) -> Void

    private var suggestions: [String] {
        if tone.isEmotionAware {
            return ["I had a rough day", "I want to talk something through", "Help me feel calmer", "I have good news"]
        }
        return useDocuments
            ? ["Summarize my documents", "What are the key dates mentioned?", "List action items I should do"]
            : ["Explain how Wi-Fi works simply", "Help me draft a polite email", "Give me a 3-day workout plan"]
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.iphone")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text(tone.isEmotionAware ? "How are you feeling today?" : "Private by design")
                .font(.title3.bold())
            Text(tone.isEmotionAware
                 ? "Talk freely. This stays on your iPhone."
                 : useDocuments
                 ? "Answers come from your documents, on this iPhone."
                 : "Runs entirely on-device. Works in airplane mode.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ForEach(suggestions, id: \.self) { suggestion in
                Button(suggestion) { pick(suggestion) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sheets

/// "Why this answer?": the query used and every passage that was given to the model.
struct SourcesSheet: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let query = message.searchQuery {
                    Section("Search query") { Text(query) }
                }
                Section("Passages given to the model") {
                    if message.sources.isEmpty {
                        Text("No documents were used for this answer.").foregroundStyle(.secondary)
                    }
                    ForEach(message.sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(source.label).font(.subheadline.bold())
                                Spacer()
                                if source.cited {
                                    Label("Cited", systemImage: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(source.text)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Why this answer?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct DocumentScopeSheet: View {
    @Bindable var conversation: Conversation
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        conversation.scopeIDs = []
                    } label: {
                        HStack {
                            Text("All documents")
                            Spacer()
                            if conversation.scopeIDs.isEmpty { Image(systemName: "checkmark") }
                        }
                    }
                }
                Section("Or choose specific documents") {
                    ForEach(environment.documents) { document in
                        Button {
                            toggle(document.id)
                        } label: {
                            HStack {
                                Text(document.title)
                                Spacer()
                                if conversation.scopeIDs.contains(document.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.primary)
            .navigationTitle("Search scope")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }

    private func toggle(_ id: UUID) {
        if let index = conversation.scopeIDs.firstIndex(of: id) {
            conversation.scopeIDs.remove(at: index)
        } else {
            conversation.scopeIDs.append(id)
        }
    }
}
