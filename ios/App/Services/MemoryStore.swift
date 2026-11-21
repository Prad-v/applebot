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

    func attach(context: ModelContext) {
        self.context = context
        reload()
    }

    func reload() {
        guard let context else {
            facts = []
            return
        }
        let records = (try? context.fetch(FetchDescriptor<MemoryRecord>())) ?? []
        facts = records.map(\.asFact).sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Block for `PromptBuilder` / `ChatPipeline`, or nil when disabled / empty.
    var promptBlock: String? {
        guard isEnabled else { return nil }
        return MemoryBudget.render(facts)
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
                let record = MemoryRecord(text: fact.text, category: fact.category, pinned: fact.pinned)
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
    }

    /// After a chat turn: try the model, fall back to heuristics.
    func learn(question: String, answer: String, engine: any LLMEngine) async {
        guard isEnabled else { return }
        var candidates: [MemoryFact] = []
        let extractor = MemoryExtractor()
        let request = extractor.extractRequest(question: question, answer: answer, existing: existingTexts)
        if let raw = try? await engine.respond(request) {
            candidates = MemoryExtractor.parse(raw).map {
                MemoryFact(text: $0, category: MemoryExtractor.categorize($0))
            }
        }
        if candidates.isEmpty {
            candidates = MemoryExtractor.heuristic(question: question, answer: answer)
        }
        ingest(candidates: candidates)
    }

    private func fetch(id: UUID, in context: ModelContext) -> MemoryRecord? {
        let descriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}
