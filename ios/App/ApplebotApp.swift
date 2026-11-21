import SwiftUI
import SwiftData

@main
struct ApplebotApp: App {
    @State private var environment = AppEnvironment()
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
            return try ModelContainer(for: Conversation.self, ChatMessage.self, configurations: configuration)
        } catch {
            fatalError("Could not create the chat database: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .modelContainer(container)
                .task { await environment.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            environment.scenePhaseChanged(phase)
        }
    }
}
