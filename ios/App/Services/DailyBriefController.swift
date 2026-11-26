import Foundation
import Observation
import LLMKit
import ConnectorKit

/// Opt-in morning / unlock brief from Calendar + memory. Shown at most once per day per profile.
@MainActor
@Observable
final class DailyBriefController {
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: key(Keys.enabled)) }
    }

    private(set) var pendingBrief: DailyBrief?
    private(set) var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var profileID: UUID

    enum Keys {
        static let enabled = "dailyBriefEnabled"
        static let lastDayKey = "dailyBriefLastDay"
    }

    init(defaults: UserDefaults = .standard, profileID: UUID) {
        self.defaults = defaults
        self.profileID = profileID
        // Inline key — cannot call instance methods before `isEnabled` is set.
        isEnabled = defaults.bool(forKey: "\(Keys.enabled).\(profileID.uuidString)")
    }

    func bind(profileID: UUID) {
        self.profileID = profileID
        isEnabled = defaults.bool(forKey: Self.storageKey(Keys.enabled, profileID: profileID))
        pendingBrief = nil
    }

    func dismiss() {
        pendingBrief = nil
    }

    func considerShowing(
        profile: PersonalProfile,
        facts: [MemoryFact],
        events: [BriefEvent],
        reminderTitles: [String] = [],
        healthLines: [String] = [],
        marketLines: [String] = [],
        now: Date = Date()
    ) {
        guard isEnabled else {
            pendingBrief = nil
            return
        }
        let day = DailyBriefBuilder.dayKey(now)
        if defaults.string(forKey: key(Keys.lastDayKey)) == day {
            return
        }
        let brief = DailyBriefBuilder.build(
            profile: profile, facts: facts, events: events,
            reminderTitles: reminderTitles, healthLines: healthLines,
            marketLines: marketLines, now: now
        )
        pendingBrief = brief
        defaults.set(day, forKey: key(Keys.lastDayKey))
    }

    func clearHistory() {
        defaults.removeObject(forKey: key(Keys.lastDayKey))
        pendingBrief = nil
    }

    private func key(_ base: String) -> String { Self.storageKey(base, profileID: profileID) }

    private static func storageKey(_ base: String, profileID: UUID) -> String {
        "\(base).\(profileID.uuidString)"
    }
}
