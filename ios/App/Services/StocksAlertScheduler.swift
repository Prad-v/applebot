import Foundation
import UserNotifications
import LLMKit

/// Local notifications for stock price / event alerts.
@MainActor
final class StocksAlertScheduler {
    nonisolated static let categoryID = "applebot.stocks.alert"
    nonisolated static let askActionID = "applebot.stocks.ask"
    nonisolated static let snoozeActionID = "applebot.stocks.snooze"
    /// Shared with `StocksBackgroundRefresh` / Info.plist (must stay nonisolated).
    nonisolated static let bgTaskIdentifier = "dev.kekaflow.applebot.stocks.refresh"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    static func makeCategory() -> UNNotificationCategory {
        let ask = UNNotificationAction(
            identifier: askActionID,
            title: "Ask Applebot",
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: snoozeActionID,
            title: "Snooze",
            options: []
        )
        return UNNotificationCategory(
            identifier: categoryID,
            actions: [ask, snooze],
            intentIdentifiers: [],
            options: []
        )
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    func notify(_ fire: StockAlertFire) async {
        guard await requestAuthorizationIfNeeded() else { return }
        let content = UNMutableNotificationContent()
        content.title = fire.title
        content.body = fire.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [
            "stockAlertID": fire.ruleID.uuidString,
            "symbol": fire.symbol,
        ]
        let request = UNNotificationRequest(
            identifier: "stock.alert.\(fire.ruleID.uuidString).\(Int(fire.firedAt.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    /// Calendar triggers for `.eventDate` rules (morning of the event).
    func rescheduleEventAlerts(rules: [StockAlertRuleInfo]) async {
        await cancelEventNotifications()
        let events = rules.filter { $0.isEnabled && $0.kind == .eventDate && $0.eventDate != nil }
        guard !events.isEmpty else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        let calendar = Calendar.current
        for rule in events {
            guard let eventDate = rule.eventDate else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: eventDate)
            comps.hour = 9
            comps.minute = 0
            let content = UNMutableNotificationContent()
            content.title = "\(rule.symbol) event today"
            content.body = rule.notes.isEmpty
                ? "You set an event reminder for \(rule.symbol). Not financial advice."
                : rule.notes
            content.sound = .default
            content.categoryIdentifier = Self.categoryID
            content.userInfo = [
                "stockAlertID": rule.id.uuidString,
                "symbol": rule.symbol,
            ]
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.eventIdentifier(ruleID: rule.id),
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    private func cancelEventNotifications() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix("stock.event.") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func eventIdentifier(ruleID: UUID) -> String {
        "stock.event.\(ruleID.uuidString)"
    }
}

/// Persists last-known quotes for offline / brief use.
enum StocksQuoteCache {
    static let key = "applebot.stocks.quoteCache"

    static func load(defaults: UserDefaults = .standard) -> [String: StockQuoteSnapshot] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([StockQuoteSnapshot].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.symbol, $0) })
    }

    static func save(_ quotes: [StockQuoteSnapshot], defaults: UserDefaults = .standard) {
        let payload = Array(quotes.prefix(40))
        defaults.set(try? JSONEncoder().encode(payload), forKey: key)
    }

    static func merge(_ incoming: [StockQuoteSnapshot], into existing: [String: StockQuoteSnapshot]) -> [String: StockQuoteSnapshot] {
        var merged = existing
        for quote in incoming {
            merged[quote.symbol] = quote
        }
        return merged
    }
}
