import Foundation
import SwiftData
import LLMKit

/// User-entered holding for the Stocks tab (not broker-synced).
@Model
final class HoldingRecord {
    var id: UUID = UUID()
    var symbol: String = ""
    var shares: Double = 0
    var avgCost: Double = 0
    var currency: String = "USD"
    var notes: String = ""
    var updatedAt: Date = Date()
    var profileID: UUID?

    init(
        symbol: String,
        shares: Double,
        avgCost: Double,
        currency: String = "USD",
        notes: String = "",
        profileID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.symbol = WatchlistItemInfo.normalizeSymbol(symbol)
        self.shares = shares
        self.avgCost = avgCost
        self.currency = currency
        self.notes = notes
        self.profileID = profileID
        self.updatedAt = updatedAt
    }

    var asInfo: HoldingInfo {
        HoldingInfo(
            id: id,
            symbol: symbol,
            shares: shares,
            avgCost: avgCost,
            currency: currency,
            notes: notes,
            updatedAt: updatedAt
        )
    }

    func apply(_ info: HoldingInfo) {
        id = info.id
        symbol = info.symbol
        shares = info.shares
        avgCost = info.avgCost
        currency = info.currency
        notes = info.notes
        updatedAt = info.updatedAt
    }
}
