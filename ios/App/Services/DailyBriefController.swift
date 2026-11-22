import Foundation
import Observation
import LLMKit
import ConnectorKit

/// Opt-in morning / unlock brief from Calendar + memory. Shown at most once per day.
@MainActor
@Observable
final class DailyBriefController {
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    private(set) var pendingBrief: DailyBrief?
    private(set) var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults

    enum Keys {
        static let enabled = "dailyBriefEnabled"
        static let lastDayKey = "dailyBriefLastDay"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
    }

    func dismiss() {
        pendingBrief = nil
    }

    /// Call when the app becomes active / unlocked. Builds a brief once per calendar day when enabled.
    func considerShowing(
        profile: PersonalProfile,
        facts: [MemoryFact],
        events: [BriefEvent],
        now: Date = Date()
    ) {
        guard isEnabled else {
            pendingBrief = nil
            return
        }
        let key = DailyBriefBuilder.dayKey(now)
        if defaults.string(forKey: Keys.lastDayKey) == key {
            return
        }
        let brief = DailyBriefBuilder.build(profile: profile, facts: facts, events: events, now: now)
        // Still show an empty-calendar greeting so the feature is discoverable once per day.
        pendingBrief = brief
        defaults.set(key, forKey: Keys.lastDayKey)
    }

    func clearHistory() {
        defaults.removeObject(forKey: Keys.lastDayKey)
        pendingBrief = nil
    }
}
