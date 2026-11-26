import Foundation
import Observation
import SwiftData
import LLMKit

/// On-device watchlist for the Stocks tab and chat context.
@MainActor
@Observable
final class WatchlistStore {
    private(set) var items: [WatchlistItemInfo] = []
    private(set) var pendingAdds: [PendingWatchlistAdd] = []

    @ObservationIgnored private weak var context: ModelContext?
    @ObservationIgnored private var profileID: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pendingKeyPrefix = "applebot.pendingWatchlistAdds."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func attach(context: ModelContext, profileID: UUID?) {
        self.context = context
        self.profileID = profileID
        reload()
        loadPending()
    }

    func bind(profileID: UUID?) {
        self.profileID = profileID
        reload()
        loadPending()
    }

    func reload() {
        guard let context else {
            items = []
            return
        }
        let records = (try? context.fetch(FetchDescriptor<WatchlistItem>())) ?? []
        let scoped = records.filter { record in
            guard let profileID else { return true }
            return record.profileID == nil || record.profileID == profileID
        }
        items = scoped.map(\.asInfo).sorted { $0.symbol < $1.symbol }
        WatchlistSymbolCache.update(from: items)
    }

    @discardableResult
    func upsert(_ info: WatchlistItemInfo) -> WatchlistItemInfo {
        guard let context else { return info }
        var stored = info
        stored.symbol = WatchlistItemInfo.normalizeSymbol(stored.symbol)
        stored.updatedAt = Date()
        guard !stored.symbol.isEmpty else { return stored }

        if let existing = fetch(id: info.id, in: context) {
            existing.apply(stored)
        } else if let bySymbol = fetch(symbol: stored.symbol, in: context) {
            stored.id = bySymbol.id
            bySymbol.apply(stored)
        } else {
            let record = WatchlistItem(
                symbol: stored.symbol,
                name: stored.name,
                groupTag: stored.groupTag,
                notes: stored.notes,
                profileID: profileID,
                createdAt: stored.createdAt,
                updatedAt: stored.updatedAt
            )
            record.id = stored.id
            context.insert(record)
        }
        try? context.save()
        reload()
        return stored
    }

    func delete(_ id: UUID) {
        guard let context else { return }
        if let record = fetch(id: id, in: context) {
            context.delete(record)
            try? context.save()
        }
        reload()
    }

    func deleteAll() {
        guard let context else { return }
        let records = (try? context.fetch(FetchDescriptor<WatchlistItem>())) ?? []
        for record in records {
            if let profileID {
                if record.profileID == nil || record.profileID == profileID {
                    context.delete(record)
                }
            } else {
                context.delete(record)
            }
        }
        try? context.save()
        reload()
    }

    func proposeAdd(_ pending: PendingWatchlistAdd) {
        let symbol = WatchlistItemInfo.normalizeSymbol(pending.symbol)
        guard !symbol.isEmpty else { return }
        if items.contains(where: { $0.symbol == symbol }) { return }
        if pendingAdds.contains(where: { $0.symbol == symbol }) { return }
        var copy = pending
        copy.symbol = symbol
        pendingAdds.insert(copy, at: 0)
        pendingAdds = Array(pendingAdds.prefix(8))
        savePending()
    }

    func confirmAdd(_ id: UUID) {
        guard let pending = pendingAdds.first(where: { $0.id == id }) else { return }
        _ = upsert(WatchlistItemInfo(symbol: pending.symbol, name: pending.name, notes: pending.reason))
        dismissAdd(id)
    }

    func dismissAdd(_ id: UUID) {
        pendingAdds.removeAll { $0.id == id }
        savePending()
    }

    func tools(quotes: [String: StockQuoteSnapshot] = [:]) -> [ToolSpec] {
        let snapshot = items
        let quoteMap = quotes
        return [
            ToolSpec(
                name: "list_watchlist",
                description:
                    "List tickers the user saved on Applebot's Stocks watchlist. "
                    + "Use when they ask about their watchlist or tracked symbols. "
                    + "Not financial advice; quotes may be delayed.",
                parameters: [],
                label: "Checking your watchlist",
                handler: { _ in
                    guard !snapshot.isEmpty else {
                        return "No watchlist symbols saved in Applebot yet. "
                            + "The user can add them in the Stocks tab. "
                            + StocksContextBudget.disclaimer
                    }
                    let lines = snapshot.map { item -> String in
                        if let quote = quoteMap[item.symbol] {
                            return "- \(quote.summaryLine)"
                        }
                        var line = "- \(item.displayLine)"
                        if !item.groupTag.isEmpty { line += " [\(item.groupTag)]" }
                        return line
                    }
                    return "Watchlist saved in Applebot:\n"
                        + lines.joined(separator: "\n")
                        + "\n"
                        + StocksContextBudget.disclaimer
                }
            )
        ]
    }

    private func fetch(id: UUID, in context: ModelContext) -> WatchlistItem? {
        let records = (try? context.fetch(FetchDescriptor<WatchlistItem>())) ?? []
        return records.first { $0.id == id }
    }

    private func fetch(symbol: String, in context: ModelContext) -> WatchlistItem? {
        let normalized = WatchlistItemInfo.normalizeSymbol(symbol)
        let records = (try? context.fetch(FetchDescriptor<WatchlistItem>())) ?? []
        return records.first { record in
            guard record.symbol == normalized else { return false }
            if let profileID {
                return record.profileID == nil || record.profileID == profileID
            }
            return true
        }
    }

    private func loadPending() {
        guard let profileID,
              let data = defaults.data(forKey: pendingKeyPrefix + profileID.uuidString),
              let decoded = try? JSONDecoder().decode([PendingWatchlistAdd].self, from: data)
        else {
            pendingAdds = []
            return
        }
        pendingAdds = decoded
    }

    private func savePending() {
        guard let profileID else { return }
        let key = pendingKeyPrefix + profileID.uuidString
        if pendingAdds.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(try? JSONEncoder().encode(pendingAdds), forKey: key)
        }
    }
}

enum WatchlistSymbolCache {
    static let key = "applebot.watchlistSymbolCache"

    struct Row: Codable, Sendable {
        var id: String
        var symbol: String
        var name: String
    }

    static func update(from items: [WatchlistItemInfo]) {
        let rows = items.map { Row(id: $0.id.uuidString, symbol: $0.symbol, name: $0.name) }
        UserDefaults.standard.set(try? JSONEncoder().encode(rows), forKey: key)
    }
}
