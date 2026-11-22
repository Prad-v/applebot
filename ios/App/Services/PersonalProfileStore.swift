import Foundation
import Observation
import LLMKit

/// On-device personal profile + pending preference confirmations (per family profile).
@MainActor
@Observable
final class PersonalProfileStore {
    private(set) var profile: PersonalProfile

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var profileID: UUID

    enum Keys {
        static let profile = "personalProfile.v1"
        static let legacy = "personalProfile.v1"
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

    func update(_ mutate: (inout PersonalProfile) -> Void) {
        var next = profile
        mutate(&next)
        profile = next
        persist()
    }

    func setDisplayName(_ name: String?) {
        update { $0.displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    }

    func setCity(_ city: String?) {
        update { $0.city = city?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    }

    func setRoles(_ roles: [String]) {
        update { $0.roles = roles }
    }

    func setReplyStyle(_ style: ReplyStyle) {
        update { $0.replyStyle = style }
    }

    func setBoundaries(_ boundaries: [String]) {
        update { $0.boundaries = boundaries }
    }

    func confirmPreference(id: UUID) {
        update { $0.confirmPreference(id: id) }
    }

    func dismissPreference(id: UUID) {
        update { $0.dismissPreference(id: id) }
    }

    func removeConfirmedPref(_ text: String) {
        update { $0.removeConfirmedPref(text) }
    }

    func absorbFacts(_ facts: [MemoryFact]) {
        update { profile in
            for fact in facts {
                profile.absorbIdentityFact(fact)
                if fact.category == .preference {
                    profile.proposePreference(fact.text)
                }
            }
        }
    }

    func replace(_ profile: PersonalProfile) {
        self.profile = profile
        persist()
    }

    func clear() {
        profile = PersonalProfile()
        defaults.removeObject(forKey: storageKey)
    }

    var promptBlock: String? { profile.render() }

    private var storageKey: String { "\(Keys.profile).\(profileID.uuidString)" }

    private func persist() {
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func load(defaults: UserDefaults, profileID: UUID) -> PersonalProfile {
        let keyed = "\(Keys.profile).\(profileID.uuidString)"
        if let data = defaults.data(forKey: keyed),
           let decoded = try? JSONDecoder().decode(PersonalProfile.self, from: data) {
            return decoded
        }
        // Migrate legacy unscoped profile into the first bind.
        if let data = defaults.data(forKey: Keys.legacy),
           let decoded = try? JSONDecoder().decode(PersonalProfile.self, from: data) {
            defaults.set(data, forKey: keyed)
            defaults.removeObject(forKey: Keys.legacy)
            return decoded
        }
        return PersonalProfile()
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
