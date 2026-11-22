import Foundation

/// One person on a shared device. Data is scoped by `id` (memory, prefs, packs, chats).
public struct FamilyProfile: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var requiresAuthToSwitch: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        requiresAuthToSwitch: Bool = true
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.requiresAuthToSwitch = requiresAuthToSwitch
    }
}

/// Registry of family profiles plus the active one.
public struct FamilyProfileRegistry: Sendable, Codable, Equatable {
    public var profiles: [FamilyProfile]
    public var activeID: UUID

    public init(profiles: [FamilyProfile], activeID: UUID) {
        self.profiles = profiles
        self.activeID = activeID
    }

    public static func bootstrap(defaultName: String = "Personal") -> FamilyProfileRegistry {
        let profile = FamilyProfile(name: defaultName, requiresAuthToSwitch: false)
        return FamilyProfileRegistry(profiles: [profile], activeID: profile.id)
    }

    public var active: FamilyProfile {
        profiles.first(where: { $0.id == activeID }) ?? profiles[0]
    }

    public mutating func add(name: String) -> FamilyProfile {
        let profile = FamilyProfile(name: name)
        profiles.append(profile)
        return profile
    }

    public mutating func rename(id: UUID, name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func remove(id: UUID) -> Bool {
        guard profiles.count > 1, profiles.contains(where: { $0.id == id }) else { return false }
        profiles.removeAll { $0.id == id }
        if activeID == id {
            activeID = profiles[0].id
        }
        return true
    }

    public mutating func select(_ id: UUID) -> Bool {
        guard profiles.contains(where: { $0.id == id }) else { return false }
        activeID = id
        return true
    }
}
