import Foundation
import Observation
import SwiftData
import LLMKit

/// User-entered holdings for the Stocks tab (not broker-synced).
@MainActor
@Observable
final class HoldingsStore {
    private(set) var holdings: [HoldingInfo] = []

    @ObservationIgnored private weak var context: ModelContext?
    @ObservationIgnored private var profileID: UUID?

    func attach(context: ModelContext, profileID: UUID?) {
        self.context = context
        self.profileID = profileID
        reload()
    }

    func bind(profileID: UUID?) {
        self.profileID = profileID
        reload()
    }

    func reload() {
        guard let context else {
            holdings = []
            return
        }
        let records = (try? context.fetch(FetchDescriptor<HoldingRecord>())) ?? []
        let scoped = records.filter { record in
            guard let profileID else { return true }
            return record.profileID == nil || record.profileID == profileID
        }
        holdings = scoped.map(\.asInfo).sorted { $0.symbol < $1.symbol }
    }

    @discardableResult
    func upsert(_ info: HoldingInfo) -> HoldingInfo {
        guard let context else { return info }
        var stored = info
        stored.symbol = WatchlistItemInfo.normalizeSymbol(stored.symbol)
        stored.updatedAt = Date()
        guard !stored.symbol.isEmpty, stored.shares > 0 else { return stored }

        if let existing = fetch(id: info.id, in: context) {
            existing.apply(stored)
        } else if let bySymbol = fetch(symbol: stored.symbol, in: context) {
            stored.id = bySymbol.id
            bySymbol.apply(stored)
        } else {
            let record = HoldingRecord(
                symbol: stored.symbol,
                shares: stored.shares,
                avgCost: stored.avgCost,
                currency: stored.currency,
                notes: stored.notes,
                profileID: profileID,
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
        let records = (try? context.fetch(FetchDescriptor<HoldingRecord>())) ?? []
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

    func tools(quotes: [String: StockQuoteSnapshot] = [:]) -> [ToolSpec] {
        let snapshot = holdings
        let quoteMap = quotes
        return [
            ToolSpec(
                name: "list_holdings",
                description:
                    "List stock/ETF holdings the user entered in Applebot's Stocks tab "
                    + "(shares and average cost; not broker-synced). "
                    + "Use for portfolio questions. Not financial advice.",
                parameters: [],
                label: "Checking your holdings",
                handler: { _ in
                    guard !snapshot.isEmpty else {
                        return "No holdings saved in Applebot yet. "
                            + "The user can add shares and average cost in the Stocks tab. "
                            + StocksContextBudget.disclaimer
                    }
                    let lines = snapshot.map { holding -> String in
                        if let quote = quoteMap[holding.symbol] {
                            let pl = holding.unrealizedPL(price: quote.price)
                            let sign = pl >= 0 ? "+" : ""
                            return "- \(holding.displayLine); last \(String(format: "%.2f", quote.price)); "
                                + "unrealized P&L \(sign)\(String(format: "%.2f", pl))"
                        }
                        return "- \(holding.displayLine)"
                    }
                    return "Holdings saved in Applebot (user-entered, not broker-synced):\n"
                        + lines.joined(separator: "\n")
                        + "\n"
                        + StocksContextBudget.disclaimer
                }
            )
        ]
    }

    private func fetch(id: UUID, in context: ModelContext) -> HoldingRecord? {
        let records = (try? context.fetch(FetchDescriptor<HoldingRecord>())) ?? []
        return records.first { $0.id == id }
    }

    private func fetch(symbol: String, in context: ModelContext) -> HoldingRecord? {
        let normalized = WatchlistItemInfo.normalizeSymbol(symbol)
        let records = (try? context.fetch(FetchDescriptor<HoldingRecord>())) ?? []
        return records.first { record in
            guard record.symbol == normalized else { return false }
            if let profileID {
                return record.profileID == nil || record.profileID == profileID
            }
            return true
        }
    }
}
