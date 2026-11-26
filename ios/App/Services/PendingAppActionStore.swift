import Foundation

/// Queued actions from notifications / App Intents until the running app can apply them.
enum PendingAppAction: Codable, Equatable, Sendable {
    case markMedicationTaken(UUID)
    case markMedicationTakenByName(String)
    case askWellnessScore
    case openHealth
    case openStocks
    case askAboutSymbol(String)
    case snoozeAlert(UUID)
    case askPortfolioSummary
}

/// Persists cross-launch actions in UserDefaults and notifies a live app via `NotificationCenter`.
final class PendingAppActionStore: @unchecked Sendable {
    static let shared = PendingAppActionStore()
    static let didEnqueue = Notification.Name("applebot.pendingAppAction.didEnqueue")

    private let defaults: UserDefaults
    private let key = "applebot.pendingAppActions"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func enqueue(_ action: PendingAppAction) {
        lock.lock()
        var queue = loadUnlocked()
        queue.append(action)
        saveUnlocked(queue)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didEnqueue, object: nil)
    }

    func drain() -> [PendingAppAction] {
        lock.lock()
        defer { lock.unlock() }
        let queue = loadUnlocked()
        saveUnlocked([])
        return queue
    }

    private func loadUnlocked() -> [PendingAppAction] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PendingAppAction].self, from: data)
        else { return [] }
        return decoded
    }

    private func saveUnlocked(_ actions: [PendingAppAction]) {
        if actions.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(try? JSONEncoder().encode(actions), forKey: key)
    }
}
