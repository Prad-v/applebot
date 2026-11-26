import Foundation
import SwiftData
import LLMKit

/// On-device price / event alert for the Stocks tab.
@Model
final class StockAlertRule {
    var id: UUID = UUID()
    var symbol: String = ""
    var kindRaw: String = StockAlertKind.above.rawValue
    var threshold: Double = 0
    var eventDate: Date?
    var isEnabled: Bool = true
    var lastFiredAt: Date?
    var cooldownSeconds: Double = 6 * 60 * 60
    var notes: String = ""
    var updatedAt: Date = Date()
    var profileID: UUID?

    init(
        symbol: String,
        kind: StockAlertKind,
        threshold: Double,
        eventDate: Date? = nil,
        isEnabled: Bool = true,
        lastFiredAt: Date? = nil,
        cooldownSeconds: TimeInterval = 6 * 60 * 60,
        notes: String = "",
        profileID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.symbol = WatchlistItemInfo.normalizeSymbol(symbol)
        self.kindRaw = kind.rawValue
        self.threshold = threshold
        self.eventDate = eventDate
        self.isEnabled = isEnabled
        self.lastFiredAt = lastFiredAt
        self.cooldownSeconds = cooldownSeconds
        self.notes = notes
        self.profileID = profileID
        self.updatedAt = updatedAt
    }

    var kind: StockAlertKind {
        get { StockAlertKind(rawValue: kindRaw) ?? .above }
        set { kindRaw = newValue.rawValue }
    }

    var asInfo: StockAlertRuleInfo {
        StockAlertRuleInfo(
            id: id,
            symbol: symbol,
            kind: kind,
            threshold: threshold,
            eventDate: eventDate,
            isEnabled: isEnabled,
            lastFiredAt: lastFiredAt,
            cooldownSeconds: cooldownSeconds,
            notes: notes,
            updatedAt: updatedAt
        )
    }

    func apply(_ info: StockAlertRuleInfo) {
        id = info.id
        symbol = info.symbol
        kind = info.kind
        threshold = info.threshold
        eventDate = info.eventDate
        isEnabled = info.isEnabled
        lastFiredAt = info.lastFiredAt
        cooldownSeconds = info.cooldownSeconds
        notes = info.notes
        updatedAt = info.updatedAt
    }
}
