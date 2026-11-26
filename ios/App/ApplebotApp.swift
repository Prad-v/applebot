import SwiftUI
import SwiftData

@main
struct ApplebotApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()
    @State private var theme = ThemeController()
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer = {
        let isUITest = ProcessInfo.processInfo.arguments.contains("-UITestMockEngine")
        let configuration: ModelConfiguration
        if isUITest {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            configuration = ModelConfiguration(url: AppPaths.dataDirectory.appendingPathComponent("chats.store"))
        }
        do {
            return try ModelContainer(
                for: Conversation.self, ChatMessage.self, MemoryRecord.self, MedicationRecord.self,
                WatchlistItem.self, HoldingRecord.self, StockAlertRule.self,
                configurations: configuration
            )
        } catch {
            fatalError("Could not create the chat database: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(theme)
                .modelContainer(container)
                .tint(theme.accent)
                .preferredColorScheme(theme.preferredColorScheme)
                .id(theme.selection) // refresh static theme colour reads when the user switches
                .task {
                    ThemeControllerBridge.controller = theme
                    await environment.start()
                }
                .onAppear { ThemeControllerBridge.controller = theme }
                .onReceive(NotificationCenter.default.publisher(for: PendingAppActionStore.didEnqueue)) { _ in
                    environment.processPendingActions()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            environment.scenePhaseChanged(phase)
        }
    }
}
