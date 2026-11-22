import Foundation
import Observation
import LLMKit

/// Persists the optional “write like me” style card (Settings / rewrite SKU).
@MainActor
@Observable
final class StyleCardStore {
    var card: StyleCard {
        didSet { persist() }
    }

    @ObservationIgnored private let defaults: UserDefaults

    enum Keys {
        static let card = "styleCard.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.card),
           let decoded = try? JSONDecoder().decode(StyleCard.self, from: data) {
            card = decoded
        } else {
            card = StyleCard()
        }
    }

    var isReady: Bool { card.isReady }

    func clear() {
        card = StyleCard()
        defaults.removeObject(forKey: Keys.card)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(card) {
            defaults.set(data, forKey: Keys.card)
        }
    }
}
