import Foundation
import Observation
import LocalAuthentication
import LLMKit

/// Family / multi-profile registry with Face ID gate when switching.
@MainActor
@Observable
final class FamilyProfileStore {
    private(set) var registry: FamilyProfileRegistry

    @ObservationIgnored private let defaults: UserDefaults

    enum Keys {
        static let registry = "familyProfiles.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.registry),
           let decoded = try? JSONDecoder().decode(FamilyProfileRegistry.self, from: data),
           !decoded.profiles.isEmpty {
            registry = decoded
        } else {
            registry = .bootstrap()
            persist()
        }
    }

    var active: FamilyProfile { registry.active }
    var activeID: UUID { registry.activeID }
    var profiles: [FamilyProfile] { registry.profiles }

    func add(name: String) -> FamilyProfile {
        let profile = registry.add(name: name)
        persist()
        return profile
    }

    func rename(id: UUID, name: String) {
        registry.rename(id: id, name: name)
        persist()
    }

    func remove(id: UUID) -> Bool {
        let ok = registry.remove(id: id)
        if ok { persist() }
        return ok
    }

    /// Switch profile. Requires device owner auth when the target asks for it (or leaving a protected profile).
    @discardableResult
    func select(_ id: UUID, authenticate: Bool = true) async -> Bool {
        guard id != activeID else { return true }
        guard let target = profiles.first(where: { $0.id == id }) else { return false }
        if authenticate, target.requiresAuthToSwitch || active.requiresAuthToSwitch {
            let ok = await authenticateOwner(reason: "Switch to \(target.name)'s Applebot profile")
            guard ok else { return false }
        }
        guard registry.select(id) else { return false }
        persist()
        return true
    }

    func setRequiresAuth(id: UUID, enabled: Bool) {
        guard let index = registry.profiles.firstIndex(where: { $0.id == id }) else { return }
        registry.profiles[index].requiresAuthToSwitch = enabled
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(registry) {
            defaults.set(data, forKey: Keys.registry)
        }
    }

    private func authenticateOwner(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode — allow switch so the user is not trapped.
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
