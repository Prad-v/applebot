import Foundation
import BackgroundTasks
import ConnectorKit
import LLMKit
import SwiftData

/// Best-effort BGAppRefresh for stock alert evaluation (no push server).
enum StocksBackgroundRefresh {
    static let taskIdentifier = "dev.kekaflow.applebot.stocks.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule(after seconds: TimeInterval = 60 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        // BGAppRefreshTask is not Sendable; the system still requires setTaskCompleted
        // from this handler's async work. Isolate the reference for Swift 6.
        nonisolated(unsafe) let bgTask = task
        let work = Task {
            let success = await runEvaluation()
            bgTask.setTaskCompleted(success: Task.isCancelled ? false : success)
        }
        bgTask.expirationHandler = { work.cancel() }
    }

    /// Load enabled rules + watchlist symbols, fetch quotes, fire notifications.
    static func runEvaluation() async -> Bool {
        let defaults = UserDefaults.standard
        let enabled = Set(defaults.stringArray(forKey: "enabledConnectors") ?? [])
        guard enabled.contains("stocks") else { return true }

        let container: ModelContainer
        do {
            let url = AppPaths.dataDirectory.appendingPathComponent("chats.store")
            let configuration = ModelConfiguration(url: url)
            container = try ModelContainer(
                for: Conversation.self, ChatMessage.self, MemoryRecord.self, MedicationRecord.self,
                WatchlistItem.self, HoldingRecord.self, StockAlertRule.self,
                configurations: configuration
            )
        } catch {
            return false
        }

        let context = ModelContext(container)
        let alertRecords = (try? context.fetch(FetchDescriptor<StockAlertRule>())) ?? []
        let rules = alertRecords.map(\.asInfo).filter(\.isEnabled)
        guard !rules.isEmpty else { return true }

        let watchRecords = (try? context.fetch(FetchDescriptor<WatchlistItem>())) ?? []
        var symbols = Set(rules.map(\.symbol))
        for item in watchRecords { symbols.insert(item.symbol) }

        let connector = StocksConnector()
        do {
            let batch = try await connector.fetchQuotes(symbols: Array(symbols))
            let snapshots = Dictionary(uniqueKeysWithValues: batch.quotes.map { ($0.symbol, $0.asSnapshot) })
            StocksQuoteCache.save(Array(snapshots.values), defaults: defaults)
            let fires = StocksAlertEvaluator.evaluate(rules: rules, quotes: snapshots)
            let scheduler = await MainActor.run { StocksAlertScheduler() }
            for fire in fires {
                await scheduler.notify(fire)
                if let record = alertRecords.first(where: { $0.id == fire.ruleID }) {
                    record.lastFiredAt = fire.firedAt
                }
            }
            try? context.save()
            return true
        } catch {
            return false
        }
    }
}
