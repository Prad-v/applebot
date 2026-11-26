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
                    emptyHome
                } else {
                    conversationHome
                }
            }
            .applebotCanvas()
            .safeAreaInset(edge: .top) { AvailabilityBanner() }
            .navigationTitle("Applebot")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: startNewChat) {
                        Image(systemName: "square.and.pencil")
                            .font(.body.weight(.medium))
                            .foregroundStyle(ApplebotTheme.accent)
                    }
                    .accessibilityLabel("New Chat")
                    .accessibilityIdentifier("new-chat")
                }
            }
            .navigationDestination(for: Conversation.self) { conversation in
                ChatView(conversation: conversation, onNewChat: startNewChat)
                    .id(conversation.id)
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

    private var emptyHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ApplebotTheme.spaceL) {
                ApplebotHeroEmpty(
                    symbol: "lock.iphone",
                    title: ApplebotGreeting.line(name: environment.profile.profile.displayName),
                    message: "Private by design. Ask anything — answers stay on this iPhone.",
                    primaryTitle: "Start chatting",
                    primarySystemImage: "bubble.left",
                    primaryAction: startNewChat
                )

                Text("On-device · no account · nothing leaves unless you opt in")
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, ApplebotTheme.spaceXL)
        }
    }

    private var conversationHome: some View {
        List {
            Section {
                Text(ApplebotGreeting.line(name: environment.profile.profile.displayName))
                    .font(ApplebotTheme.display(22))
                    .foregroundStyle(ApplebotTheme.ink)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 2, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                Text(visible.count == 1
                     ? "1 conversation"
                     : "\(visible.count) conversations")
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(filtered) { conversation in
                    NavigationLink(value: conversation) {
                        ConversationRowLite(conversation: conversation)
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .leading) {
                        Button {
                            conversation.pinned.toggle()
                        } label: {
                            Label(conversation.pinned ? "Unpin" : "Pin", systemImage: conversation.pinned ? "pin.slash" : "pin")
                        }
                        .tint(ApplebotTheme.warning)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            deleteConversation(conversation)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            conversation.pinned.toggle()
                        } label: {
                            Label(conversation.pinned ? "Unpin" : "Pin",
                                  systemImage: conversation.pinned ? "pin.slash" : "pin")
                        }
                        Button(role: .destructive) {
                            deleteConversation(conversation)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: "Search")
    }

    /// Start a brand new conversation: no history, no summary, search scope reset to all documents.
    private func startNewChat() {
        let conversation = Conversation(
            useDocuments: !environment.documents.isEmpty,
            profileID: environment.activeProfileID
        )
        modelContext.insert(conversation)
        path = [conversation]
    }

    /// Delete a saved chat and pop navigation if it was open.
    private func deleteConversation(_ conversation: Conversation) {
        path.removeAll { $0.id == conversation.id }
        modelContext.delete(conversation)
        try? modelContext.save()
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

/// Flat conversation row — typography + hairline, no card chrome.
private struct ConversationRowLite: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if conversation.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(ApplebotTheme.warning)
                }
                Text(conversation.title)
                    .font(.system(.body, design: .default).weight(.medium))
                    .foregroundStyle(ApplebotTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(conversation.updatedAt, style: .relative)
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(ApplebotTheme.tertiaryInk)
            }
            Text(conversation.lastMessagePreview)
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
