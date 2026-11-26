import Foundation
import Observation
import ConnectorKit
import LLMKit

/// Loads watchlist quotes for the Stocks tab and builds market awareness.
@MainActor
@Observable
final class StocksDashboardController {
    private(set) var isConnectorEnabled = false
    private(set) var isLoading = false
    private(set) var isRefreshingInsight = false
    private(set) var errorMessage: String?
    private(set) var quotes: [StockQuoteSnapshot] = []
    private(set) var quoteMap: [String: StockQuoteSnapshot] = [:]
    private(set) var failures: [String] = []
    private(set) var session: MarketSession = MarketSession.usEquity()
    private(set) var insightNarrative: String?
    private(set) var lastRefreshed: Date?
    private(set) var concentrationLine: String?

    @ObservationIgnored private var stocksConnector: StocksConnector?
    @ObservationIgnored private var isEnabled: (() async -> Bool)?
    @ObservationIgnored private var engine: (() -> any LLMEngine)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        quoteMap = StocksQuoteCache.load(defaults: defaults)
        quotes = Array(quoteMap.values).sorted { $0.symbol < $1.symbol }
    }

    var moversSummary: String {
        guard !quotes.isEmpty else { return "No quotes yet" }
        let up = quotes.filter { ($0.changePercent ?? 0) > 0 }.count
        let down = quotes.filter { ($0.changePercent ?? 0) < 0 }.count
        return "\(up) up · \(down) down · \(quotes.count) loaded"
    }

    var briefMarketLines: [String] {
        DailyBriefBuilder.marketLines(quotes: quotes, session: session)
    }

    func configure(
        connector: StocksConnector,
        isEnabled: @escaping () async -> Bool,
        engine: @escaping () -> any LLMEngine
    ) {
        self.stocksConnector = connector
        self.isEnabled = isEnabled
        self.engine = engine
    }

    func refreshStatus() async {
        isConnectorEnabled = await isEnabled?() ?? false
        session = MarketSession.usEquity()
    }

    func enableConnector() async {
        // Caller flips registry; we only refresh status after.
        await refreshStatus()
    }

    func refresh(
        watchlist: [WatchlistItemInfo],
        holdings: [HoldingInfo] = [],
        includeInsight: Bool = true
    ) async {
        await refreshStatus()
        session = MarketSession.usEquity()
        guard isConnectorEnabled, let connector = stocksConnector else {
            errorMessage = isConnectorEnabled ? nil : "Turn on Stocks under You → Connectors."
            return
        }

        var symbols = watchlist.map(\.symbol)
        for holding in holdings where !symbols.contains(holding.symbol) {
            symbols.append(holding.symbol)
        }
        guard !symbols.isEmpty else {
            quotes = []
            failures = []
            concentrationLine = nil
            lastRefreshed = Date()
            if includeInsight { insightNarrative = nil }
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let batch = try await connector.fetchQuotes(symbols: symbols)
            let snapshots = batch.quotes.map(\.asSnapshot)
            quoteMap = StocksQuoteCache.merge(snapshots, into: quoteMap)
            StocksQuoteCache.save(Array(quoteMap.values), defaults: defaults)
            quotes = snapshots.sorted { abs($0.changePercent ?? 0) > abs($1.changePercent ?? 0) }
            failures = batch.failures
            lastRefreshed = Date()
            concentrationLine = StocksContextBudget.concentrationLine(holdings: holdings, quotes: quoteMap)

            // Backfill names onto empty watchlist names happens in the view/store layer.
            if includeInsight {
                await regenerateInsight(holdings: holdings)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep cached quotes visible.
            quotes = symbols.compactMap { quoteMap[$0] }
        }
    }

    func clearInsights() {
        insightNarrative = nil
        quotes = []
        quoteMap = [:]
        failures = []
        concentrationLine = nil
        lastRefreshed = nil
        errorMessage = nil
        defaults.removeObject(forKey: StocksQuoteCache.key)
    }

    func regenerateInsight(holdings: [HoldingInfo]) async {
        guard let engine else { return }
        guard !quotes.isEmpty else {
            insightNarrative = nil
            return
        }
        isRefreshingInsight = true
        defer { isRefreshingInsight = false }
        let request = StocksInsightBuilder.narrativeRequest(
            quotes: quotes,
            holdings: holdings,
            concentration: concentrationLine,
            session: session
        )
        do {
            let raw = try await engine().respond(request)
            insightNarrative = Self.normalizeInsight(raw)
        } catch {
            if insightNarrative == nil {
                insightNarrative = fallbackInsight(holdings: holdings)
            }
        }
    }

    func askPrompt(kind: StocksAskKind, holdings: [HoldingInfo] = []) -> String {
        StocksInsightBuilder.askPrompt(kind: kind, quotes: quotes, holdings: holdings)
    }

    func suggestAlerts(for symbol: String) -> [StockAlertRuleInfo] {
        guard let quote = quoteMap[WatchlistItemInfo.normalizeSymbol(symbol)] ?? quotes.first(where: {
            $0.symbol == WatchlistItemInfo.normalizeSymbol(symbol)
        }) else { return [] }
        return StocksAlertEvaluator.suggestedRules(for: quote)
    }

    private static func normalizeInsight(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("DISCLAIMER:") {
            return trimmed
        }
        return trimmed + "\n\nDISCLAIMER: " + StocksInsightBuilder.userFacingDisclaimer
    }

    private func fallbackInsight(holdings: [HoldingInfo]) -> String {
        var parts = [
            "Watchlist: \(moversSummary). Session: \(session.displayName).",
        ]
        if let top = quotes.first {
            parts.append("Largest move among loaded quotes: \(top.summaryLine).")
        }
        if let concentrationLine {
            parts.append(concentrationLine)
        } else if !holdings.isEmpty {
            parts.append("You have \(holdings.count) holding\(holdings.count == 1 ? "" : "s") saved on this iPhone.")
        }
        parts.append("DISCLAIMER: " + StocksInsightBuilder.userFacingDisclaimer)
        return parts.joined(separator: "\n\n")
    }
}
