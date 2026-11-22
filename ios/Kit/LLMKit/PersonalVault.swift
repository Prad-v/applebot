import Foundation

/// Portable snapshot of personal AI state for encrypted export/restore.
public struct PersonalVaultPayload: Sendable, Codable, Equatable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    public var profileName: String
    public var personalProfile: PersonalProfile
    public var styleCard: StyleCard
    public var memories: [MemoryFact]
    public var documents: [VaultDocument]
    public var retrievalWeights: RetrievalWeights
    public var automations: [AutomationRecipe]

    public init(
        formatVersion: Int = formatVersion,
        exportedAt: Date = Date(),
        profileName: String,
        personalProfile: PersonalProfile,
        styleCard: StyleCard,
        memories: [MemoryFact],
        documents: [VaultDocument] = [],
        retrievalWeights: RetrievalWeights = .default,
        automations: [AutomationRecipe] = []
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.profileName = profileName
        self.personalProfile = personalProfile
        self.styleCard = styleCard
        self.memories = memories
        self.documents = documents
        self.retrievalWeights = retrievalWeights
        self.automations = automations
    }
}

public struct VaultDocument: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var pack: String?
    public var text: String

    public init(id: UUID = UUID(), title: String, pack: String? = nil, text: String) {
        self.id = id
        self.title = title
        self.pack = pack
        self.text = text
    }
}

/// Password-based envelope (CryptoKit used by the app layer). Portable encode/decode only here.
public enum PersonalVaultCodec {
    public static func encodePayload(_ payload: PersonalVaultPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    public static func decodePayload(_ data: Data) throws -> PersonalVaultPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(PersonalVaultPayload.self, from: data)
        guard payload.formatVersion <= PersonalVaultPayload.formatVersion else {
            throw VaultError.unsupportedVersion(payload.formatVersion)
        }
        return payload
    }

    public enum VaultError: Error, Sendable, Equatable, LocalizedError {
        case unsupportedVersion(Int)
        case corrupt
        case badPassword

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "This backup was made with a newer Applebot (format \(v))."
            case .corrupt: return "The backup file is damaged or not an Applebot pack."
            case .badPassword: return "That password does not unlock this backup."
            }
        }
    }
}
