import Foundation
import Observation
import LLMKit

/// Local automation recipes (foreground due-check; user confirms before running).
@MainActor
@Observable
final class AutomationStore {
    private(set) var recipes: [AutomationRecipe]
    private(set) var dueRecipe: AutomationRecipe?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var profileID: UUID

    enum Keys {
        static let recipes = "automations.v1"
    }

    init(defaults: UserDefaults = .standard, profileID: UUID) {
        self.defaults = defaults
        self.profileID = profileID
        recipes = Self.load(defaults: defaults, profileID: profileID)
    }

    func bind(profileID: UUID) {
        self.profileID = profileID
        recipes = Self.load(defaults: defaults, profileID: profileID)
        dueRecipe = nil
    }

    func replace(_ recipes: [AutomationRecipe]) {
        self.recipes = recipes
        persist()
    }

    func upsert(_ recipe: AutomationRecipe) {
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
        persist()
    }

    func delete(_ id: UUID) {
        recipes.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes[index].isEnabled = enabled
        persist()
    }

    func considerDue(now: Date = Date()) {
        dueRecipe = AutomationScheduler.due(recipes: recipes, now: now).first
    }

    func dismissDue() { dueRecipe = nil }

    func markDueRan() {
        guard let due = dueRecipe else { return }
        let updated = AutomationScheduler.markRan(due)
        upsert(updated)
        dueRecipe = nil
    }

    func installTemplatesIfEmpty() {
        guard recipes.isEmpty else { return }
        recipes = AutomationRecipe.templates
        persist()
    }

    func clear() {
        recipes = []
        dueRecipe = nil
        defaults.removeObject(forKey: key)
    }

    private var key: String { "\(Keys.recipes).\(profileID.uuidString)" }

    private func persist() {
        if let data = try? JSONEncoder().encode(recipes) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load(defaults: UserDefaults, profileID: UUID) -> [AutomationRecipe] {
        let key = "\(Keys.recipes).\(profileID.uuidString)"
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([AutomationRecipe].self, from: data) {
            return decoded
        }
        return []
    }
}
