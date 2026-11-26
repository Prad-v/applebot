import Foundation
import Observation
import LLMKit

/// On-device behavioral twin card (routines, interests, stress) per family profile.
@MainActor
@Observable
final class BehavioralProfileStore {
    private(set) var profile: BehavioralProfile

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var profileID: UUID

    enum Keys {
        static let profile = "behavioralProfile.v1"
    }

    init(defaults: UserDefaults = .standard, profileID: UUID) {
        self.defaults = defaults
        self.profileID = profileID
        profile = Self.load(defaults: defaults, profileID: profileID)
    }

    func bind(profileID: UUID) {
        self.profileID = profileID
        profile = Self.load(defaults: defaults, profileID: profileID)
    }

    var isEnabled: Bool {
        get { profile.isEnabled }
        set {
            update { $0.isEnabled = newValue }
        }
    }

    var summaryLine: String {
        guard profile.isEnabled else { return "Off" }
        if !profile.hasSummary { return "Learning" }
        var parts: [String] = []
        if let sleep = profile.typicalSleepHours {
            parts.append(String(format: "%.0fh sleep", sleep))
        }
        if let interest = profile.topInterests.first {
            parts.append(interest.topic.displayName)
        }
        if parts.isEmpty { return "On" }
        return parts.joined(separator: " · ")
    }

    func update(_ mutate: (inout BehavioralProfile) -> Void) {
        var next = profile
        mutate(&next)
        profile = next
        persist()
    }

    func ingestDays(_ samples: [BehavioralDaySample]) {
        guard !samples.isEmpty else { return }
        profile = BehavioralSummarizer.ingestDays(samples, into: profile)
        persist()
    }

    func ingestTurn(_ turn: BehavioralTurnSignal) {
        profile = BehavioralSummarizer.ingestTurn(turn, into: profile)
        persist()
    }

    func replace(_ profile: BehavioralProfile) {
        self.profile = profile
        persist()
    }

    func clear() {
        profile = BehavioralProfile()
        defaults.removeObject(forKey: storageKey)
    }

    var promptBlock: String? { BehavioralContextBudget.render(profile) }

    private var storageKey: String { "\(Keys.profile).\(profileID.uuidString)" }

    private func persist() {
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func load(defaults: UserDefaults, profileID: UUID) -> BehavioralProfile {
        let keyed = "\(Keys.profile).\(profileID.uuidString)"
        if let data = defaults.data(forKey: keyed),
           let decoded = try? JSONDecoder().decode(BehavioralProfile.self, from: data) {
            return decoded
        }
        return BehavioralProfile()
    }
}
