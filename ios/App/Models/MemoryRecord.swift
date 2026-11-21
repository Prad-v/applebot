import Foundation
import SwiftData
import LLMKit

/// Persisted cross-chat memory fact (SwiftData). Encrypted at rest with the chats store.
@Model
final class MemoryRecord {
    var id: UUID = UUID()
    var text: String = ""
    var categoryRaw: String = MemoryFact.Category.other.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var pinned: Bool = false

    init(text: String, category: MemoryFact.Category = .other, pinned: Bool = false) {
        self.text = text
        self.categoryRaw = category.rawValue
        self.pinned = pinned
    }

    var category: MemoryFact.Category {
        get { MemoryFact.Category(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var asFact: MemoryFact {
        MemoryFact(id: id, text: text, category: category, updatedAt: updatedAt, pinned: pinned)
    }

    func apply(_ fact: MemoryFact) {
        id = fact.id
        text = fact.text
        category = fact.category
        updatedAt = fact.updatedAt
        pinned = fact.pinned
    }
}
