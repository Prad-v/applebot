import Foundation
import Observation
import SwiftData
import LLMKit

/// Loads, merges and saves cross-chat memories. All data stays in the on-device SwiftData store.
@MainActor
@Observable
final class MemoryStore {
    private(set) var facts: [MemoryFact] = []
    /// Master switch (Settings). When off, nothing is injected or extracted.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var context: ModelContext?
    @ObservationIgnored private weak var profileStore: PersonalProfileStore?

    enum Keys {
        static let enabled = "memoryEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Default on for companion product; missing key → true.
        if defaults.object(forKey: Keys.enabled) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Keys.enabled)
        }
    }

    func attach(context: ModelContext, profile: PersonalProfileStore? = nil) {
        self.context = context
        self.profileStore = profile
        reload()
        purgeExpired()
    }

    func reload() {
        guard let context else {
            facts = []
            return
        }
        let records = (try? context.fetch(FetchDescriptor<MemoryRecord>())) ?? []
        facts = MemoryBudget.rank(records.map(\.asFact))
    }

    /// Block for `PromptBuilder` / `ChatPipeline`, or nil when disabled / empty.
    /// Prefer `personalContext(profile:)` when a profile store is available.
    var promptBlock: String? {
        guard isEnabled else { return nil }
        return MemoryBudget.render(facts)
    }

    func personalContext(profile: PersonalProfile) -> String? {
        guard isEnabled else { return profile.render() }
        return PersonalContextBudget.render(profile: profile, facts: facts)
    }

    var existingTexts: [String] { facts.map(\.text) }

    func delete(_ fact: MemoryFact) {
        guard let context else { return }
        if let record = fetch(id: fact.id, in: context) {
            context.delete(record)
            try? context.save()
        }
        reload()
    }

    func togglePin(_ fact: MemoryFact) {
        guard let context, let record = fetch(id: fact.id, in: context) else { return }
        record.pinned.toggle()
        record.updatedAt = Date()
        try? context.save()
        reload()
    }

    func deleteAll() {
        guard let context else { return }
        try? context.delete(model: MemoryRecord.self)
        try? context.save()
        facts = []
    }

    /// Drop expired unpinned facts from the store.
    func purgeExpired(now: Date = Date()) {
        guard let context else { return }
        let records = (try? context.fetch(FetchDescriptor<MemoryRecord>())) ?? []
        var changed = false
        for record in records {
            if let expires = record.expiresAt, expires < now, !record.pinned {
                context.delete(record)
                changed = true
            }
        }
        if changed {
            try? context.save()
            reload()
        }
    }

    /// Merge model/heuristic candidates into the store.
    func ingest(candidates: [MemoryFact]) {
        guard isEnabled, !candidates.isEmpty, let context else { return }
        let merged = MemoryBudget.merge(existing: facts, adding: candidates)
        let existing = (try? context.fetch(FetchDescriptor<MemoryRecord>())) ?? []
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let mergedIDs = Set(merged.map(\.id))

        for fact in merged {
            if let record = byID[fact.id] {
                record.apply(fact)
            } else {
                let record = MemoryRecord(
                    text: fact.text,
                    category: fact.category,
                    pinned: fact.pinned,
                    confidence: fact.confidence,
                    expiresAt: fact.expiresAt,
                    lastUsedAt: fact.lastUsedAt
                )
                record.id = fact.id
                record.updatedAt = fact.updatedAt
                context.insert(record)
                byID[fact.id] = record
            }
        }
        for record in existing where !mergedIDs.contains(record.id) {
            context.delete(record)
        }
        try? context.save()
        reload()
        profileStore?.absorbFacts(candidates)
    }

    /// After a chat turn: try the model, fall back to heuristics.
    /// Preference facts become pending profile confirmations instead of silent memory.
    func learn(question: String, answer: String, engine: any LLMEngine) async {
        guard isEnabled else { return }
        var candidates: [MemoryFact] = []
        let extractor = MemoryExtractor()
        let request = extractor.extractRequest(question: question, answer: answer, existing: existingTexts)
        if let raw = try? await engine.respond(request) {
            candidates = MemoryExtractor.parse(raw).map { MemoryExtractor.fact(from: $0) }
        }
        if candidates.isEmpty {
            candidates = MemoryExtractor.heuristic(question: question, answer: answer)
        }

        let preferences = candidates.filter { $0.category == .preference }
        let durable = candidates.filter { $0.category != .preference }
        if !preferences.isEmpty {
            profileStore?.absorbFacts(preferences)
        }
        // Identity facts still update the profile even when stored as memory.
        profileStore?.absorbFacts(durable.filter { $0.category == .person || $0.category == .place })
        ingest(candidates: durable)
    }

    /// Mark facts that were injected into the last prompt as recently used.
    func markPromptUsage(from block: String?) {
        guard let block, let context else { return }
        let injected = Set(facts.map(\.text).filter { block.contains($0) })
        guard !injected.isEmpty else { return }
        let now = Date()
        for fact in facts where injected.contains(fact.text) {
            if let record = fetch(id: fact.id, in: context) {
                record.lastUsedAt = now
            }
        }
        try? context.save()
        reload()
    }

    private func fetch(id: UUID, in context: ModelContext) -> MemoryRecord? {
        let descriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}
