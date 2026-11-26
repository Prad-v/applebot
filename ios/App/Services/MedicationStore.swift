import Foundation
import Observation
import SwiftData
import LLMKit

/// Applebot-only medications for the Health tab and chat context.
@MainActor
@Observable
final class MedicationStore {
    private(set) var medications: [MedicationInfo] = []

    @ObservationIgnored private weak var context: ModelContext?
    @ObservationIgnored private var profileID: UUID?
    @ObservationIgnored private let reminders = MedicationReminderScheduler()

    var confirmed: [MedicationInfo] {
        medications.filter(\.userConfirmed).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var reminderNames: [String] {
        confirmed.filter(\.remindersEnabled).map(\.name)
    }

    func attach(context: ModelContext, profileID: UUID?) {
        self.context = context
        self.profileID = profileID
        reload()
        Task { await reminders.reschedule(medications: confirmed) }
    }

    func bind(profileID: UUID?) {
        self.profileID = profileID
        reload()
        Task { await reminders.reschedule(medications: confirmed) }
    }

    func reload() {
        guard let context else {
            medications = []
            return
        }
        let records = (try? context.fetch(FetchDescriptor<MedicationRecord>())) ?? []
        let scoped = records.filter { record in
            guard let profileID else { return true }
            return record.profileID == nil || record.profileID == profileID
        }
        medications = scoped.map(\.asInfo).sorted { $0.updatedAt > $1.updatedAt }
        MedicationNameCache.update(from: medications)
    }

    @discardableResult
    func upsert(_ info: MedicationInfo) -> MedicationInfo {
        guard let context else { return info }
        var stored = info
        stored.updatedAt = Date()
        stored.reminderTimes = MedicationInfo.normalizeTimes(stored.reminderTimes)
        if let existing = fetch(id: info.id, in: context) {
            existing.apply(stored)
        } else {
            let record = MedicationRecord(
                name: stored.name,
                dose: stored.dose,
                frequency: stored.frequency,
                notes: stored.notes,
                source: stored.source,
                ocrRawText: stored.ocrRawText,
                userConfirmed: stored.userConfirmed,
                profileID: profileID,
                remindersEnabled: stored.remindersEnabled,
                reminderTimes: stored.reminderTimes,
                lastTakenAt: stored.lastTakenAt
            )
            record.id = stored.id
            record.updatedAt = stored.updatedAt
            context.insert(record)
        }
        try? context.save()
        reload()
        Task { await reminders.reschedule(medications: confirmed) }
        return stored
    }

    func markTaken(_ id: UUID, at date: Date = Date()) {
        guard var info = medications.first(where: { $0.id == id }) else { return }
        info.lastTakenAt = date
        _ = upsert(info)
    }

    /// Mark taken by spoken / Siri name. Returns the matched medication when found.
    @discardableResult
    func markTaken(named raw: String, at date: Date = Date()) -> MedicationInfo? {
        guard let match = MedicationInfo.bestMatch(named: raw, in: confirmed) else { return nil }
        markTaken(match.id, at: date)
        return medications.first(where: { $0.id == match.id }) ?? match
    }

    func delete(_ id: UUID) {
        guard let context else { return }
        if let record = fetch(id: id, in: context) {
            context.delete(record)
            try? context.save()
        }
        reload()
        Task {
            await reminders.cancel(medicationID: id)
            await reminders.reschedule(medications: confirmed)
        }
    }

    func deleteAll() {
        guard let context else { return }
        let records = (try? context.fetch(FetchDescriptor<MedicationRecord>())) ?? []
        for record in records {
            if let profileID {
                if record.profileID == nil || record.profileID == profileID {
                    context.delete(record)
                }
            } else {
                context.delete(record)
            }
        }
        try? context.save()
        reload()
        Task { await reminders.reschedule(medications: []) }
    }

    /// Snapshot tools for the chat pipeline (confirmed meds only).
    func tools() -> [ToolSpec] {
        let snapshot = confirmed
        return [
            ToolSpec(
                name: "list_user_medications",
                description:
                    "List medications the user saved in Applebot's Health tab (not Apple Health writes). "
                    + "Includes reminder times and whether taken today when known. "
                    + "Use when they ask what meds they take, doses, or medication awareness. "
                    + "Not medical advice.",
                parameters: [],
                label: "Checking your medications",
                handler: { _ in
                    guard !snapshot.isEmpty else {
                        return "No medications saved in Applebot yet. "
                            + "The user can add them in the Health tab (manual or photo). "
                            + HealthContextBudget.disclaimer
                    }
                    let lines = snapshot.map { med -> String in
                        var line = "- \(med.displayLine) (\(med.source.displayName))"
                        if med.remindersEnabled, !med.reminderTimes.isEmpty {
                            line += "; reminders \(med.reminderTimes.joined(separator: ", "))"
                        }
                        if med.takenToday() {
                            line += "; marked taken today"
                        }
                        return line
                    }
                    return "Medications saved in Applebot:\n"
                        + lines.joined(separator: "\n")
                        + "\n"
                        + HealthContextBudget.disclaimer
                }
            )
        ]
    }

    private func fetch(id: UUID, in context: ModelContext) -> MedicationRecord? {
        let records = (try? context.fetch(FetchDescriptor<MedicationRecord>())) ?? []
        return records.first { $0.id == id }
    }
}
