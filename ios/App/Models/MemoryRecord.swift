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
    var confidence: Double = 0.7
    var expiresAt: Date?
    var lastUsedAt: Date?

    init(
        text: String,
        category: MemoryFact.Category = .other,
        pinned: Bool = false,
        confidence: Double = 0.7,
        expiresAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.text = text
        self.categoryRaw = category.rawValue
        self.pinned = pinned
        self.confidence = confidence
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
    }

    var category: MemoryFact.Category {
        get { MemoryFact.Category(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var asFact: MemoryFact {
        MemoryFact(
            id: id,
            text: text,
            category: category,
            updatedAt: updatedAt,
            pinned: pinned,
            confidence: confidence,
            expiresAt: expiresAt,
            lastUsedAt: lastUsedAt
        )
    }

    func apply(_ fact: MemoryFact) {
        id = fact.id
        text = fact.text
        category = fact.category
        updatedAt = fact.updatedAt
        pinned = fact.pinned
        confidence = fact.confidence
        expiresAt = fact.expiresAt
        lastUsedAt = fact.lastUsedAt
    }
}
