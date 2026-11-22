import Foundation
import Observation
import LLMKit

/// On-device personal profile + pending preference confirmations (UserDefaults JSON).
@MainActor
@Observable
final class PersonalProfileStore {
    private(set) var profile: PersonalProfile

    @ObservationIgnored private let defaults: UserDefaults

    enum Keys {
        static let profile = "personalProfile.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.profile),
           let decoded = try? JSONDecoder().decode(PersonalProfile.self, from: data) {
            profile = decoded
        } else {
            profile = PersonalProfile()
        }
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

    func clear() {
        profile = PersonalProfile()
        defaults.removeObject(forKey: Keys.profile)
    }

    var promptBlock: String? { profile.render() }

    private func persist() {
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: Keys.profile)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
