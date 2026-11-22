import Foundation
import Observation
import LLMKit
import RAGKit

/// Per-profile hybrid retrieval weights adapted from thumbs feedback.
@MainActor
@Observable
final class RetrievalTunerStore {
    private(set) var weights: RetrievalWeights

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var profileID: UUID

    enum Keys {
        static let weights = "retrievalWeights.v1"
    }

    init(defaults: UserDefaults = .standard, profileID: UUID) {
        self.defaults = defaults
        self.profileID = profileID
        weights = Self.load(defaults: defaults, profileID: profileID)
    }

    func bind(profileID: UUID) {
        self.profileID = profileID
        weights = Self.load(defaults: defaults, profileID: profileID)
    }

    var retrievalConfig: RetrievalConfig {
        RetrievalConfig(weights: weights)
    }

    func recordFeedback(helpful: Bool, citedHadVector: Bool, citedHadKeyword: Bool) {
        weights = weights.applying(
            helpful: helpful,
            citedHadVector: citedHadVector,
            citedHadKeyword: citedHadKeyword
        )
        persist()
    }

    func apply(_ weights: RetrievalWeights) {
        self.weights = weights
        persist()
    }

    func reset() {
        weights = .default
        defaults.removeObject(forKey: key)
    }

    private var key: String { "\(Keys.weights).\(profileID.uuidString)" }

    private func persist() {
        if let data = try? JSONEncoder().encode(weights) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load(defaults: UserDefaults, profileID: UUID) -> RetrievalWeights {
        let key = "\(Keys.weights).\(profileID.uuidString)"
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(RetrievalWeights.self, from: data) {
            return decoded
        }
        return .default
    }
}
