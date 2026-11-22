import Foundation
import Observation
import LLMKit

/// Opt-in proactive check-ins for open loops / relationship continuity.
@MainActor
@Observable
final class CheckInController {
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: key(Keys.enabled)) }
    }

    private(set) var pending: CheckInSuggestion?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var profileID: UUID

    enum Keys {
        static let enabled = "checkInsEnabled"
        static let lastAt = "checkInsLastAt"
    }

    init(defaults: UserDefaults = .standard, profileID: UUID) {
        self.defaults = defaults
        self.profileID = profileID
        // Inline key — cannot call instance methods before `isEnabled` is set.
        isEnabled = defaults.object(forKey: "\(Keys.enabled).\(profileID.uuidString)") as? Bool ?? false
    }

    func bind(profileID: UUID) {
        self.profileID = profileID
        isEnabled = defaults.object(forKey: Self.storageKey(Keys.enabled, profileID: profileID)) as? Bool ?? false
        pending = nil
    }

    func dismiss() { pending = nil }

    func consider(facts: [MemoryFact], now: Date = Date()) {
        guard isEnabled else {
            pending = nil
            return
        }
        let last = defaults.object(forKey: key(Keys.lastAt)) as? Date
        if let suggestion = CheckInPlanner.suggest(facts: facts, lastCheckInAt: last, now: now) {
            pending = suggestion
            defaults.set(now, forKey: key(Keys.lastAt))
        }
    }

    func clearHistory() {
        defaults.removeObject(forKey: key(Keys.lastAt))
        pending = nil
    }

    private func key(_ base: String) -> String { Self.storageKey(base, profileID: profileID) }

    private static func storageKey(_ base: String, profileID: UUID) -> String {
        "\(base).\(profileID.uuidString)"
    }
}
