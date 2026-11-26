import UIKit
import UserNotifications
import BackgroundTasks

/// Registers notification categories, background refresh, and routes actions into `PendingAppActionStore`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            MedicationReminderScheduler.makeCategory(),
            StocksAlertScheduler.makeCategory(),
        ])
        StocksBackgroundRefresh.register()
        StocksBackgroundRefresh.schedule()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        StocksBackgroundRefresh.schedule()
    }

    // Foreground presentation so reminders still show while Applebot is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        let medicationID = (userInfo["medicationID"] as? String).flatMap(UUID.init(uuidString:))
        let stockAlertID = (userInfo["stockAlertID"] as? String).flatMap(UUID.init(uuidString:))
        let symbol = userInfo["symbol"] as? String

        switch response.actionIdentifier {
        case MedicationReminderScheduler.takenActionID:
            if let medicationID {
                PendingAppActionStore.shared.enqueue(.markMedicationTaken(medicationID))
            }
        case StocksAlertScheduler.askActionID:
            if let symbol, !symbol.isEmpty {
                PendingAppActionStore.shared.enqueue(.askAboutSymbol(symbol))
            } else {
                PendingAppActionStore.shared.enqueue(.openStocks)
            }
        case StocksAlertScheduler.snoozeActionID:
            if let stockAlertID {
                PendingAppActionStore.shared.enqueue(.snoozeAlert(stockAlertID))
            }
        case UNNotificationDefaultActionIdentifier:
            if medicationID != nil {
                PendingAppActionStore.shared.enqueue(.openHealth)
            } else if stockAlertID != nil || symbol != nil {
                PendingAppActionStore.shared.enqueue(.openStocks)
            }
        default:
            break
        }
    }
}
