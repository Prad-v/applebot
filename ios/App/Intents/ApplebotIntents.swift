import AppIntents
import Foundation
import LLMKit

/// Cached medication for Siri / Shortcuts (names synced from `MedicationStore`).
struct MedicationEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Medication")
    static let defaultQuery = MedicationEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MedicationEntityQuery: EntityQuery {
    func entities(for identifiers: [MedicationEntity.ID]) async throws -> [MedicationEntity] {
        let all = MedicationEntityQuery.cachedMedications()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MedicationEntity] {
        MedicationEntityQuery.cachedMedications()
    }

    static func cachedMedications() -> [MedicationEntity] {
        guard let data = UserDefaults.standard.data(forKey: MedicationNameCache.key),
              let rows = try? JSONDecoder().decode([MedicationNameCache.Row].self, from: data)
        else { return [] }
        return rows.map { MedicationEntity(id: $0.id, name: $0.name) }
    }
}

enum MedicationNameCache {
    static let key = "applebot.medicationNameCache"

    struct Row: Codable, Sendable {
        var id: String
        var name: String
    }

    static func update(from medications: [MedicationInfo]) {
        let rows = medications
            .filter(\.userConfirmed)
            .map { Row(id: $0.id.uuidString, name: $0.name) }
        UserDefaults.standard.set(try? JSONEncoder().encode(rows), forKey: key)
    }
}

/// Siri / Shortcuts: mark an Applebot-only medication as taken today.
struct MarkMedicationTakenIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark medication taken"
    static let description = IntentDescription(
        "Logs that you took a medication saved in Applebot’s Health tab. Does not write to Apple Health."
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Medication")
    var medication: MedicationEntity

    init() {
        self.medication = MedicationEntity(id: "", name: "")
    }

    init(medication: MedicationEntity) {
        self.medication = medication
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$medication) taken in Applebot")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let id = UUID(uuidString: medication.id) {
            PendingAppActionStore.shared.enqueue(.markMedicationTaken(id))
        } else {
            PendingAppActionStore.shared.enqueue(.markMedicationTakenByName(medication.name))
        }
        PendingAppActionStore.shared.enqueue(.openHealth)
        return .result(dialog: "Marked \(medication.name) as taken in Applebot. Not medical advice.")
    }
}

/// Siri / Shortcuts: open Chat with a wellness-score prompt.
struct AskWellnessScoreIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask about wellness score"
    static let description = IntentDescription(
        "Opens Applebot Chat to explain your on-device wellness score. Not medical advice."
    )
    static let openAppWhenRun: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Applebot about my wellness score")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingAppActionStore.shared.enqueue(.askWellnessScore)
        return .result(dialog: "Opening Applebot to talk about your wellness score.")
    }
}

/// Siri / Shortcuts: open the Stocks tab watchlist.
struct OpenWatchlistIntent: AppIntent {
    static let title: LocalizedStringResource = "Open watchlist"
    static let description = IntentDescription(
        "Opens Applebot’s Stocks tab to your on-device watchlist. Quotes may be delayed. Not financial advice."
    )
    static let openAppWhenRun: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Open my Applebot watchlist")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingAppActionStore.shared.enqueue(.openStocks)
        return .result(dialog: "Opening your Applebot watchlist.")
    }
}

/// Cached watchlist symbol for Siri / Shortcuts (synced from `WatchlistStore`).
struct WatchlistSymbolEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Watchlist Symbol")
    static let defaultQuery = WatchlistSymbolEntityQuery()

    var id: String
    var symbol: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        if name.isEmpty {
            return DisplayRepresentation(title: "\(symbol)")
        }
        return DisplayRepresentation(title: "\(symbol)", subtitle: "\(name)")
    }
}

struct WatchlistSymbolEntityQuery: EntityQuery {
    func entities(for identifiers: [WatchlistSymbolEntity.ID]) async throws -> [WatchlistSymbolEntity] {
        let all = WatchlistSymbolEntityQuery.cachedSymbols()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WatchlistSymbolEntity] {
        WatchlistSymbolEntityQuery.cachedSymbols()
    }

    static func cachedSymbols() -> [WatchlistSymbolEntity] {
        guard let data = UserDefaults.standard.data(forKey: WatchlistSymbolCache.key),
              let rows = try? JSONDecoder().decode([WatchlistSymbolCache.Row].self, from: data)
        else { return [] }
        return rows.map { WatchlistSymbolEntity(id: $0.id, symbol: $0.symbol, name: $0.name) }
    }
}

/// Siri / Shortcuts: ask about a ticker in Chat (watchlist AppEntity — required for App Shortcut phrases).
struct AskStockQuoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask about a stock"
    static let description = IntentDescription(
        "Opens Applebot Chat to look up a ticker from your watchlist. Quotes may be delayed. Not financial advice."
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Symbol")
    var symbol: WatchlistSymbolEntity

    init() {
        self.symbol = WatchlistSymbolEntity(id: "", symbol: "", name: "")
    }

    init(symbol: WatchlistSymbolEntity) {
        self.symbol = symbol
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Applebot about \(\.$symbol)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = symbol.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else {
            PendingAppActionStore.shared.enqueue(.openStocks)
            return .result(dialog: "Opening Stocks in Applebot.")
        }
        PendingAppActionStore.shared.enqueue(.askAboutSymbol(trimmed))
        return .result(dialog: "Opening Applebot to talk about \(trimmed). Not financial advice.")
    }
}

/// Siri / Shortcuts: portfolio / holdings summary in Chat.
struct AskPortfolioSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask about portfolio"
    static let description = IntentDescription(
        "Opens Applebot Chat to summarize holdings you entered on-device. Not financial advice."
    )
    static let openAppWhenRun: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Applebot about my portfolio")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingAppActionStore.shared.enqueue(.askPortfolioSummary)
        return .result(dialog: "Opening Applebot to talk about your holdings. Not financial advice.")
    }
}

/// Donates phrases to Siri Suggestions / App Shortcuts.
struct ApplebotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MarkMedicationTakenIntent(),
            phrases: [
                "Mark \(\.$medication) taken in \(.applicationName)",
                "Log that I took \(\.$medication) in \(.applicationName)",
                "I took \(\.$medication) in \(.applicationName)",
            ],
            shortTitle: "Mark taken",
            systemImageName: "pills"
        )
        AppShortcut(
            intent: AskWellnessScoreIntent(),
            phrases: [
                "What's my wellness score in \(.applicationName)",
                "Ask \(.applicationName) about my wellness score",
                "Explain my wellness score in \(.applicationName)",
            ],
            shortTitle: "Wellness score",
            systemImageName: "heart.text.square"
        )
        AppShortcut(
            intent: OpenWatchlistIntent(),
            phrases: [
                "Open my watchlist in \(.applicationName)",
                "Show my stocks in \(.applicationName)",
            ],
            shortTitle: "Watchlist",
            systemImageName: "chart.line.uptrend.xyaxis"
        )
        AppShortcut(
            intent: AskStockQuoteIntent(),
            phrases: [
                "What's \(\.$symbol) doing in \(.applicationName)",
                "Ask \(.applicationName) about \(\.$symbol)",
            ],
            shortTitle: "Stock quote",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: AskPortfolioSummaryIntent(),
            phrases: [
                "How's my portfolio in \(.applicationName)",
                "Summarize my holdings in \(.applicationName)",
            ],
            shortTitle: "Portfolio",
            systemImageName: "chart.pie"
        )
    }
}
