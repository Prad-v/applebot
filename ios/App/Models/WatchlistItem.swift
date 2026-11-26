import Foundation
import SwiftData
import LLMKit

/// Persisted watchlist ticker for the Stocks tab (on-device only).
@Model
final class WatchlistItem {
    var id: UUID = UUID()
    var symbol: String = ""
    var name: String = ""
    var groupTag: String = ""
    var notes: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var profileID: UUID?

    init(
        symbol: String,
        name: String = "",
        groupTag: String = "",
        notes: String = "",
        profileID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.symbol = WatchlistItemInfo.normalizeSymbol(symbol)
        self.name = name
        self.groupTag = groupTag
        self.notes = notes
        self.profileID = profileID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var asInfo: WatchlistItemInfo {
        WatchlistItemInfo(
            id: id,
            symbol: symbol,
            name: name,
            groupTag: groupTag,
            notes: notes,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func apply(_ info: WatchlistItemInfo) {
        id = info.id
        symbol = info.symbol
        name = info.name
        groupTag = info.groupTag
        notes = info.notes
        createdAt = info.createdAt
        updatedAt = info.updatedAt
    }
}
