import Foundation

/// Rules for which documents a single conversation searches.
///
/// A scope is a list of document IDs. **An empty list means "all documents"**. Attaching files to a
/// chat narrows the scope to those files (plus anything already attached), so a chat about one PDF
/// is not polluted by the rest of the library.
public enum DocumentScope {
    /// Add `ids` to the scope, keeping order and removing duplicates.
    ///
    /// Attaching to an "all documents" chat narrows it to just the new documents.
    public static func attaching(_ ids: [UUID], to current: [UUID]) -> [UUID] {
        guard !ids.isEmpty else { return current }
        var result = current
        for id in ids where !result.contains(id) { result.append(id) }
        return result
    }

    /// Remove one document from the scope. Removing the last one returns an empty scope, which
    /// means "all documents" again.
    public static func removing(_ id: UUID, from current: [UUID]) -> [UUID] {
        current.filter { $0 != id }
    }

    /// Drop IDs of documents that no longer exist (for example after deleting them in the library).
    public static func pruned(_ current: [UUID], existing: Set<UUID>) -> [UUID] {
        current.filter { existing.contains($0) }
    }

    /// The set to hand to `KnowledgeBase.search(scope:)`; `nil` searches everything.
    public static func searchScope(_ current: [UUID], existing: Set<UUID>) -> Set<UUID>? {
        let live = pruned(current, existing: existing)
        return live.isEmpty ? nil : Set(live)
    }
}
