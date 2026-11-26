import Foundation

/// Portable counts from a RoomPlan `CapturedRoom` (filled by the app layer).
public struct RoomScanFacts: Sendable, Equatable, Codable, Hashable {
    public var wallCount: Int
    public var doorCount: Int
    public var windowCount: Int
    public var openingCount: Int
    public var objectLabels: [String]
    public var capturedAt: Date

    public init(
        wallCount: Int = 0,
        doorCount: Int = 0,
        windowCount: Int = 0,
        openingCount: Int = 0,
        objectLabels: [String] = [],
        capturedAt: Date = Date()
    ) {
        self.wallCount = max(0, wallCount)
        self.doorCount = max(0, doorCount)
        self.windowCount = max(0, windowCount)
        self.openingCount = max(0, openingCount)
        self.objectLabels = objectLabels
        self.capturedAt = capturedAt
    }

    public var isEmpty: Bool {
        wallCount == 0 && doorCount == 0 && windowCount == 0 && openingCount == 0 && objectLabels.isEmpty
    }
}

/// Saved scan metadata (USDZ lives on disk beside this index).
public struct RoomScanRecord: Sendable, Equatable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var facts: RoomScanFacts
    public var usdzFileName: String
    public var byteSize: Int

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        facts: RoomScanFacts,
        usdzFileName: String,
        byteSize: Int = 0
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.facts = facts
        self.usdzFileName = usdzFileName
        self.byteSize = max(0, byteSize)
    }
}

/// Builds spoken / chat summaries of a room scan without importing RoomPlan (Linux-safe).
public enum RoomScanNarrator {
    public static let safetyDisclaimer =
        "Room scan is a rough 3D model for reference. Measurements can be wrong. "
        + "Not for construction, legal plans, or safety-critical navigation."

    public static func factSheet(_ facts: RoomScanFacts) -> String {
        var lines: [String] = ["Room scan facts:"]
        lines.append("- Walls: \(facts.wallCount)")
        lines.append("- Doors: \(facts.doorCount)")
        lines.append("- Windows: \(facts.windowCount)")
        lines.append("- Openings: \(facts.openingCount)")
        if facts.objectLabels.isEmpty {
            lines.append("- Objects: (none detected)")
        } else {
            let counts = Dictionary(grouping: facts.objectLabels, by: { $0 }).mapValues(\.count)
            let summary = counts.keys.sorted().map { key in
                let n = counts[key] ?? 1
                return n > 1 ? "\(key) ×\(n)" : key
            }.joined(separator: ", ")
            lines.append("- Objects: \(summary)")
        }
        return lines.joined(separator: "\n")
    }

    public static func mechanicalSummary(_ facts: RoomScanFacts) -> String {
        if facts.isEmpty {
            return "This scan has no clear walls or objects yet. " + safetyDisclaimer
        }
        var parts: [String] = []
        parts.append(
            "Scan includes \(facts.wallCount) wall\(facts.wallCount == 1 ? "" : "s"), "
                + "\(facts.doorCount) door\(facts.doorCount == 1 ? "" : "s"), "
                + "and \(facts.windowCount) window\(facts.windowCount == 1 ? "" : "s")."
        )
        if !facts.objectLabels.isEmpty {
            let unique = Array(Set(facts.objectLabels)).sorted().prefix(6)
            parts.append("Detected furniture or objects include: \(unique.joined(separator: ", ")).")
        }
        parts.append(safetyDisclaimer)
        return parts.joined(separator: " ")
    }

    public static func narrationRequest(facts: RoomScanFacts) -> LLMRequest {
        LLMRequest(
            instructions:
                "You summarize a RoomPlan 3D room scan for the user in plain language. "
                + "Use ONLY the provided facts. 3 to 5 short sentences. "
                + "Describe layout roughly (walls, doors, windows, furniture). "
                + "Do not invent rooms or objects. Mention that measurements can be approximate. "
                + "End with a brief note that this is not for construction or navigation. No emoji.",
            prompt: factSheet(facts),
            temperature: 0.3,
            maximumResponseTokens: 180
        )
    }

    public static func normalizeModelOutput(_ raw: String, facts: RoomScanFacts) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return mechanicalSummary(facts) }
        if trimmed.lowercased().contains("not for") || trimmed.lowercased().contains("approximate") {
            return trimmed
        }
        return trimmed + " " + safetyDisclaimer
    }
}
