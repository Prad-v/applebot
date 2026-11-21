import Foundation
import SwiftData
import LLMKit

/// A saved chat. Messages are stored separately and ordered by `createdAt`.
@Model
final class Conversation {
    var id: UUID = UUID()
    var title: String = "New chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var pinned: Bool = false

    /// Rolling summary of the oldest turns that no longer fit in the model's context window.
    var summary: String?
    /// How many valid messages (oldest first) have already been folded into `summary`.
    var summarizedCount: Int = 0

    /// Ground answers in the user's documents.
    var useDocuments: Bool = true
    /// Document IDs to search. Empty means all documents.
    var scopeIDs: [UUID] = []

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []

    init(useDocuments: Bool = true) {
        self.useDocuments = useDocuments
    }

    /// Messages in chronological order, excluding failed ones.
    var orderedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    var validMessages: [ChatMessage] {
        orderedMessages.filter { !$0.isError }
    }

    var lastMessagePreview: String {
        orderedMessages.last?.text.replacingOccurrences(of: "\n", with: " ") ?? "No messages yet"
    }
}

/// One message in a conversation.
@Model
final class ChatMessage {
    var id: UUID = UUID()
    var roleRaw: String = Turn.Role.user.rawValue
    var text: String = ""
    var createdAt: Date = Date()
    var isError: Bool = false

    /// Retrieval details for assistant messages (JSON-encoded `[SourceRef]`).
    var sourcesData: Data?
    var notFound: Bool = false
    var searchQuery: String?
    /// Connector actions used for this answer, for example "Searching Gmail". Shown under the reply.
    var toolsUsed: [String] = []

    var conversation: Conversation?

    init(role: Turn.Role, text: String) {
        self.roleRaw = role.rawValue
        self.text = text
    }

    var role: Turn.Role {
        Turn.Role(rawValue: roleRaw) ?? .user
    }

    var sources: [SourceRef] {
        get {
            guard let sourcesData else { return [] }
            return (try? JSONDecoder().decode([SourceRef].self, from: sourcesData)) ?? []
        }
        set {
            sourcesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    var citedSources: [SourceRef] { sources.filter(\.cited) }
}

/// A retrieved passage shown under an answer.
struct SourceRef: Codable, Hashable, Identifiable {
    var index: Int          // 1-based citation number
    var title: String
    var location: String?
    var text: String
    var cited: Bool

    var id: Int { index }

    var label: String {
        var label = "[\(index)] \(title)"
        if let location { label += " · \(location)" }
        return label
    }
}
