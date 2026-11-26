import Foundation
import UserNotifications
import LLMKit

/// Schedules local notifications for Applebot-only medication reminder times.
@MainActor
final class MedicationReminderScheduler {
    static let categoryID = "applebot.medication.dose"
    static let takenActionID = "applebot.medication.taken"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    static func makeCategory() -> UNNotificationCategory {
        let taken = UNNotificationAction(
            identifier: takenActionID,
            title: "Taken",
            options: [.authenticationRequired]
        )
        return UNNotificationCategory(
            identifier: categoryID,
            actions: [taken],
            intentIdentifiers: [],
            options: []
        )
    }

    /// Call once at launch so reminders show a **Taken** action.
    /// Prefer registering alongside other Applebot categories from `AppDelegate`.
    static func registerCategories(on center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories([makeCategory()])
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Replace all Applebot medication notifications with the current confirmed, enabled set.
    func reschedule(medications: [MedicationInfo]) async {
        await cancelAllMedicationNotifications()
        let enabled = medications.filter { $0.userConfirmed && $0.remindersEnabled && !$0.reminderTimes.isEmpty }
        guard !enabled.isEmpty else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        for med in enabled {
            for time in med.reminderTimes {
                guard let (hour, minute) = Self.parse(time) else { continue }
                var date = DateComponents()
                date.hour = hour
                date.minute = minute
                let content = UNMutableNotificationContent()
                content.title = "Medication reminder"
                content.body = med.dose.isEmpty ? "Time for \(med.name)" : "Time for \(med.name) (\(med.dose))"
                content.sound = .default
                content.categoryIdentifier = Self.categoryID
                content.userInfo = ["medicationID": med.id.uuidString]
                let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
                let request = UNNotificationRequest(
                    identifier: Self.identifier(medID: med.id, time: time),
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }
    }

    func cancel(medicationID: UUID) async {
        let pending = await center.pendingNotificationRequests()
        let prefix = "med.\(medicationID.uuidString)."
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func cancelAllMedicationNotifications() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix("med.") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func identifier(medID: UUID, time: String) -> String {
        "med.\(medID.uuidString).\(time)"
    }

    static func parse(_ time: String) -> (Int, Int)? {
        guard let normalized = MedicationInfo.normalizeTime(time) else { return nil }
        let parts = normalized.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return (hour, minute)
    }
}
