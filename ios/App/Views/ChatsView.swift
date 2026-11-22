import SwiftUI
import SwiftData

struct ChatsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var path: [Conversation] = []
    @State private var search = ""

    /// Conversations with at least one message; empty drafts are never listed.
    /// Scoped to the active family profile (legacy nil profile chats stay visible).
    private var visible: [Conversation] {
        let pid = environment.activeProfileID
        return conversations.filter { conversation in
            guard !conversation.messages.isEmpty else { return false }
            return conversation.profileID == nil || conversation.profileID == pid
        }
    }

    private var filtered: [Conversation] {
        let matches = search.isEmpty ? visible : visible.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(search)
                || conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
        return matches.sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if visible.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(filtered) { conversation in
                            NavigationLink(value: conversation) {
                                ConversationRow(conversation: conversation)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    conversation.pinned.toggle()
                                } label: {
                                    Label(conversation.pinned ? "Unpin" : "Pin", systemImage: conversation.pinned ? "pin.slash" : "pin")
                                }
                                .tint(.orange)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { modelContext.delete(filtered[index]) }
                        }
                    }
                    .searchable(text: $search, prompt: "Search chats")
                }
            }
            .safeAreaInset(edge: .top) { AvailabilityBanner() }
            .navigationTitle("Chats")
            .navigationDestination(for: Conversation.self) { conversation in
                ChatView(conversation: conversation, onNewChat: startNewChat)
                    .id(conversation.id)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: startNewChat) {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("new-chat")
                }
            }
        }
        .onChange(of: path) { _, _ in discardEmptyDrafts() }
        .onAppear { discardEmptyDrafts() }
        .onChange(of: environment.pendingChatPrompt) { _, prompt in
            guard let prompt, !prompt.isEmpty else { return }
            environment.pendingChatPrompt = nil
            let conversation = Conversation(
                useDocuments: !environment.documents.isEmpty,
                profileID: environment.activeProfileID
            )
            modelContext.insert(conversation)
            path = [conversation]
            // ChatView sends on appear via a one-shot; stash on conversation title seed.
            conversation.title = String(prompt.prefix(40))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NotificationCenter.default.post(
                    name: .applebotSendPrompt,
                    object: nil,
                    userInfo: ["text": prompt, "conversationID": conversation.id.uuidString]
                )
            }
        }
        .onChange(of: environment.activeProfileID) { _, _ in
            path = []
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No chats yet", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("Everything you ask is answered on this iPhone. No internet needed.")
        } actions: {
            Button("Start chatting", action: startNewChat)
                .buttonStyle(.borderedProminent)
        }
    }

    /// Start a brand new conversation: no history, no summary, search scope reset to all documents.
    /// If a chat screen is open it is replaced, so Back returns to the list rather than the old chat.
    private func startNewChat() {
        let conversation = Conversation(
            useDocuments: !environment.documents.isEmpty,
            profileID: environment.activeProfileID
        )
        modelContext.insert(conversation)
        path = [conversation]
    }

    /// Remove conversations that never received a message (and are not currently open).
    private func discardEmptyDrafts() {
        for conversation in conversations where conversation.messages.isEmpty && !path.contains(conversation) {
            modelContext.delete(conversation)
        }
    }
}

extension Notification.Name {
    static let applebotSendPrompt = Notification.Name("applebotSendPrompt")
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if conversation.pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
                }
                Text(conversation.title).font(.headline).lineLimit(1)
                Spacer()
                Text(conversation.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(conversation.lastMessagePreview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
