import Foundation
import SwiftData
import LLMKit

/// Persisted Applebot-only medication (never written to Apple Health).
@Model
final class MedicationRecord {
    var id: UUID = UUID()
    var name: String = ""
    var dose: String = ""
    var frequency: String = ""
    var notes: String = ""
    var sourceRaw: String = MedicationSource.manual.rawValue
    var ocrRawText: String?
    var userConfirmed: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var profileID: UUID?
    var remindersEnabled: Bool = false
    /// JSON-encoded `[String]` of `HH:mm` times.
    var reminderTimesData: Data?
    var lastTakenAt: Date?

    init(
        name: String,
        dose: String = "",
        frequency: String = "",
        notes: String = "",
        source: MedicationSource = .manual,
        ocrRawText: String? = nil,
        userConfirmed: Bool = true,
        profileID: UUID? = nil,
        remindersEnabled: Bool = false,
        reminderTimes: [String] = [],
        lastTakenAt: Date? = nil
    ) {
        self.name = name
        self.dose = dose
        self.frequency = frequency
        self.notes = notes
        self.sourceRaw = source.rawValue
        self.ocrRawText = ocrRawText
        self.userConfirmed = userConfirmed
        self.profileID = profileID
        self.remindersEnabled = remindersEnabled
        self.reminderTimesData = Self.encodeTimes(reminderTimes)
        self.lastTakenAt = lastTakenAt
    }

    var source: MedicationSource {
        get { MedicationSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    var reminderTimes: [String] {
        get { Self.decodeTimes(reminderTimesData) }
        set { reminderTimesData = Self.encodeTimes(newValue) }
    }

    var asInfo: MedicationInfo {
        MedicationInfo(
            id: id,
            name: name,
            dose: dose,
            frequency: frequency,
            notes: notes,
            source: source,
            ocrRawText: ocrRawText,
            userConfirmed: userConfirmed,
            updatedAt: updatedAt,
            remindersEnabled: remindersEnabled,
            reminderTimes: reminderTimes,
            lastTakenAt: lastTakenAt
        )
    }

    func apply(_ info: MedicationInfo) {
        id = info.id
        name = info.name
        dose = info.dose
        frequency = info.frequency
        notes = info.notes
        source = info.source
        ocrRawText = info.ocrRawText
        userConfirmed = info.userConfirmed
        updatedAt = info.updatedAt
        remindersEnabled = info.remindersEnabled
        reminderTimes = info.reminderTimes
        lastTakenAt = info.lastTakenAt
    }

    private static func encodeTimes(_ times: [String]) -> Data? {
        let normalized = MedicationInfo.normalizeTimes(times)
        guard !normalized.isEmpty else { return nil }
        return try? JSONEncoder().encode(normalized)
    }

    private static func decodeTimes(_ data: Data?) -> [String] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return MedicationInfo.normalizeTimes(decoded)
    }
}
