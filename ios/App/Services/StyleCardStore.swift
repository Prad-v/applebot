import Foundation
import Observation
import LLMKit

/// Persists the optional “write like me” style card (per family profile).
@MainActor
@Observable
final class StyleCardStore {
    var card: StyleCard {
        didSet { persist() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var profileID: UUID

    enum Keys {
        static let card = "styleCard.v1"
        static let legacy = "styleCard.v1"
    }

    init(defaults: UserDefaults = .standard, profileID: UUID) {
        self.defaults = defaults
        self.profileID = profileID
        card = Self.load(defaults: defaults, profileID: profileID)
    }

    func bind(profileID: UUID) {
        self.profileID = profileID
        card = Self.load(defaults: defaults, profileID: profileID)
    }

    var isReady: Bool { card.isReady }

    func replace(_ card: StyleCard) {
        self.card = card
    }

    func clear() {
        card = StyleCard()
        defaults.removeObject(forKey: storageKey)
    }

    private var storageKey: String { "\(Keys.card).\(profileID.uuidString)" }

    private func persist() {
        if let data = try? JSONEncoder().encode(card) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func load(defaults: UserDefaults, profileID: UUID) -> StyleCard {
        let keyed = "\(Keys.card).\(profileID.uuidString)"
        if let data = defaults.data(forKey: keyed),
           let decoded = try? JSONDecoder().decode(StyleCard.self, from: data) {
            return decoded
        }
        if let data = defaults.data(forKey: Keys.legacy),
           let decoded = try? JSONDecoder().decode(StyleCard.self, from: data) {
            defaults.set(data, forKey: keyed)
            defaults.removeObject(forKey: Keys.legacy)
            return decoded
        }
        return StyleCard()
    }
}
