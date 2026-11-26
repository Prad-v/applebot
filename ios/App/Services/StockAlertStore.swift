import Foundation
import Observation
import SwiftData
import LLMKit

/// On-device stock alert rules for the Stocks tab.
@MainActor
@Observable
final class StockAlertStore {
    private(set) var rules: [StockAlertRuleInfo] = []
    private(set) var pendingAlerts: [PendingStockAlert] = []

    @ObservationIgnored private weak var context: ModelContext?
    @ObservationIgnored private var profileID: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pendingKeyPrefix = "applebot.pendingStockAlerts."
    @ObservationIgnored private let scheduler = StocksAlertScheduler()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func attach(context: ModelContext, profileID: UUID?) {
        self.context = context
        self.profileID = profileID
        reload()
        loadPending()
        Task { await scheduler.rescheduleEventAlerts(rules: rules) }
    }

    func bind(profileID: UUID?) {
        self.profileID = profileID
        reload()
        loadPending()
        Task { await scheduler.rescheduleEventAlerts(rules: rules) }
    }

    func reload() {
        guard let context else {
            rules = []
            return
        }
        let records = (try? context.fetch(FetchDescriptor<StockAlertRule>())) ?? []
        let scoped = records.filter { record in
            guard let profileID else { return true }
            return record.profileID == nil || record.profileID == profileID
        }
        rules = scoped.map(\.asInfo).sorted { $0.symbol < $1.symbol }
    }

    @discardableResult
    func upsert(_ info: StockAlertRuleInfo) -> StockAlertRuleInfo {
        guard let context else { return info }
        var stored = info
        stored.symbol = WatchlistItemInfo.normalizeSymbol(stored.symbol)
        stored.updatedAt = Date()
        guard !stored.symbol.isEmpty else { return stored }

        if let existing = fetch(id: info.id, in: context) {
            existing.apply(stored)
        } else {
            let record = StockAlertRule(
                symbol: stored.symbol,
                kind: stored.kind,
                threshold: stored.threshold,
                eventDate: stored.eventDate,
                isEnabled: stored.isEnabled,
                lastFiredAt: stored.lastFiredAt,
                cooldownSeconds: stored.cooldownSeconds,
                notes: stored.notes,
                profileID: profileID,
                updatedAt: stored.updatedAt
            )
            record.id = stored.id
            context.insert(record)
        }
        try? context.save()
        reload()
        Task { await scheduler.rescheduleEventAlerts(rules: rules) }
        return stored
    }

    func markFired(_ id: UUID, at date: Date = Date()) {
        guard var info = rules.first(where: { $0.id == id }) else { return }
        info.lastFiredAt = date
        _ = upsert(info)
    }

    func snooze(_ id: UUID, for seconds: TimeInterval = 6 * 60 * 60) {
        guard var info = rules.first(where: { $0.id == id }) else { return }
        info.lastFiredAt = Date()
        info.cooldownSeconds = max(info.cooldownSeconds, seconds)
        _ = upsert(info)
    }

    func delete(_ id: UUID) {
        guard let context else { return }
        if let record = fetch(id: id, in: context) {
            context.delete(record)
            try? context.save()
        }
        reload()
        Task { await scheduler.rescheduleEventAlerts(rules: rules) }
    }

    func deleteAll() {
        guard let context else { return }
        let records = (try? context.fetch(FetchDescriptor<StockAlertRule>())) ?? []
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
        Task { await scheduler.rescheduleEventAlerts(rules: []) }
    }

    func proposeAlert(_ pending: PendingStockAlert) {
        if pendingAlerts.contains(where: {
            $0.rule.symbol == pending.rule.symbol && $0.rule.kind == pending.rule.kind
                && abs($0.rule.threshold - pending.rule.threshold) < 0.0001
        }) { return }
        pendingAlerts.insert(pending, at: 0)
        pendingAlerts = Array(pendingAlerts.prefix(8))
        savePending()
    }

    func confirmAlert(_ id: UUID) {
        guard let pending = pendingAlerts.first(where: { $0.id == id }) else { return }
        _ = upsert(pending.rule)
        dismissAlert(id)
    }

    func dismissAlert(_ id: UUID) {
        pendingAlerts.removeAll { $0.id == id }
        savePending()
    }

    /// Evaluate price rules against quotes and fire local notifications.
    func evaluateAndNotify(quotes: [String: StockQuoteSnapshot]) async {
        let fires = StocksAlertEvaluator.evaluate(rules: rules, quotes: quotes)
        guard !fires.isEmpty else { return }
        await scheduler.requestAuthorizationIfNeeded()
        for fire in fires {
            await scheduler.notify(fire)
            markFired(fire.ruleID, at: fire.firedAt)
        }
    }

    private func fetch(id: UUID, in context: ModelContext) -> StockAlertRule? {
        let records = (try? context.fetch(FetchDescriptor<StockAlertRule>())) ?? []
        return records.first { $0.id == id }
    }

    private func loadPending() {
        guard let profileID,
              let data = defaults.data(forKey: pendingKeyPrefix + profileID.uuidString),
              let decoded = try? JSONDecoder().decode([PendingStockAlert].self, from: data)
        else {
            pendingAlerts = []
            return
        }
        pendingAlerts = decoded
    }

    private func savePending() {
        guard let profileID else { return }
        let key = pendingKeyPrefix + profileID.uuidString
        if pendingAlerts.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(try? JSONEncoder().encode(pendingAlerts), forKey: key)
        }
    }
}
