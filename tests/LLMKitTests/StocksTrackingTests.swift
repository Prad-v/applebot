import XCTest
@testable import LLMKit

final class StocksTrackingTests: XCTestCase {
    func testNormalizeSymbol() {
        XCTAssertEqual(WatchlistItemInfo.normalizeSymbol("  aapl "), "AAPL")
    }

    func testContextBudgetRendersWatchlistAndHoldings() {
        let watch = [WatchlistItemInfo(symbol: "AAPL", name: "Apple")]
        let holding = [HoldingInfo(symbol: "AAPL", shares: 10, avgCost: 150)]
        let quote = StockQuoteSnapshot(symbol: "AAPL", name: "Apple", price: 180, previousClose: 175)
        let block = StocksContextBudget.render(
            watchlist: watch,
            holdings: holding,
            quotes: ["AAPL": quote]
        )
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("AAPL"))
        XCTAssertTrue(block!.contains("Holdings"))
        XCTAssertTrue(block!.contains("financial advice") || block!.contains("Not financial") || block!.contains("delayed"))
    }

    func testContextBudgetNilWhenEmpty() {
        XCTAssertNil(StocksContextBudget.render(watchlist: [], holdings: []))
    }

    func testConcentrationLine() {
        let holdings = [
            HoldingInfo(symbol: "AAPL", shares: 100, avgCost: 100),
            HoldingInfo(symbol: "MSFT", shares: 1, avgCost: 100),
        ]
        let quotes: [String: StockQuoteSnapshot] = [
            "AAPL": StockQuoteSnapshot(symbol: "AAPL", price: 200),
            "MSFT": StockQuoteSnapshot(symbol: "MSFT", price: 200),
        ]
        let line = StocksContextBudget.concentrationLine(holdings: holdings, quotes: quotes)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("AAPL"))
    }

    func testInsightRequestIncludesDisclaimerInstruction() {
        let quotes = [
            StockQuoteSnapshot(symbol: "AAPL", price: 190, previousClose: 188),
            StockQuoteSnapshot(symbol: "MSFT", price: 400, previousClose: 410),
        ]
        let request = StocksInsightBuilder.narrativeRequest(
            quotes: quotes,
            holdings: [HoldingInfo(symbol: "AAPL", shares: 5, avgCost: 150)],
            concentration: "AAPL is about 80% of listed holdings.",
            session: .open
        )
        XCTAssertTrue(request.instructions.contains("DISCLAIMER"))
        XCTAssertTrue(request.prompt.contains("AAPL"))
        XCTAssertTrue(request.prompt.contains("Market session"))
    }

    func testAskPrompts() {
        let quotes = [StockQuoteSnapshot(symbol: "NVDA", price: 100, previousClose: 90)]
        let movers = StocksInsightBuilder.askPrompt(kind: .movers, quotes: quotes)
        XCTAssertTrue(movers.contains("NVDA") || movers.contains("watchlist"))
        XCTAssertTrue(movers.localizedCaseInsensitiveContains("not financial advice"))
        let why = StocksInsightBuilder.askPrompt(kind: .whyMoved, quotes: quotes)
        XCTAssertTrue(why.contains("NVDA"))
    }

    func testAlertEvaluatorPriceAbove() {
        let rule = StockAlertRuleInfo(symbol: "AAPL", kind: .above, threshold: 180)
        let quote = StockQuoteSnapshot(symbol: "AAPL", price: 190, previousClose: 185)
        // Mid-day so quiet hours don't suppress.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 6
        comps.day = 12
        comps.hour = 15
        let noon = calendar.date(from: comps)!
        let fires = StocksAlertEvaluator.evaluate(
            rules: [rule],
            quotes: ["AAPL": quote],
            now: noon,
            calendar: calendar,
            respectQuietHours: true
        )
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires[0].symbol, "AAPL")
    }

    func testAlertEvaluatorRespectsCooldown() {
        var rule = StockAlertRuleInfo(symbol: "AAPL", kind: .above, threshold: 100, cooldownSeconds: 3600)
        rule.lastFiredAt = Date()
        let quote = StockQuoteSnapshot(symbol: "AAPL", price: 200)
        let fires = StocksAlertEvaluator.evaluate(
            rules: [rule],
            quotes: ["AAPL": quote],
            now: Date(),
            respectQuietHours: false
        )
        XCTAssertTrue(fires.isEmpty)
    }

    func testAlertEvaluatorDayPercent() {
        let rule = StockAlertRuleInfo(symbol: "TSLA", kind: .dayPercent, threshold: 5)
        let quote = StockQuoteSnapshot(symbol: "TSLA", price: 220, previousClose: 200)
        let fires = StocksAlertEvaluator.evaluate(
            rules: [rule],
            quotes: ["TSLA": quote],
            respectQuietHours: false
        )
        XCTAssertEqual(fires.count, 1)
    }

    func testSuggestedRules() {
        let quote = StockQuoteSnapshot(
            symbol: "AAPL", price: 180, previousClose: 175,
            yearHigh: 200, yearLow: 140
        )
        let rules = StocksAlertEvaluator.suggestedRules(for: quote)
        XCTAssertFalse(rules.isEmpty)
        XCTAssertTrue(rules.contains(where: { $0.kind == .dayPercent }))
    }

    func testMarketSessionWeekendClosed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // A known Sunday
        let comps = DateComponents(year: 2024, month: 6, day: 9, hour: 12)
        let sunday = calendar.date(from: comps)!
        XCTAssertEqual(MarketSession.usEquity(at: sunday), .closed)
    }

    func testMarketLinesHelper() {
        let quotes = [
            StockQuoteSnapshot(symbol: "AAPL", price: 190, previousClose: 180),
            StockQuoteSnapshot(symbol: "MSFT", price: 400, previousClose: 410),
        ]
        let lines = DailyBriefBuilder.marketLines(quotes: quotes, session: .open)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.contains(where: { $0.contains("open") || $0.contains("Watchlist") || $0.contains("AAPL") }))
        XCTAssertLessThanOrEqual(lines.count, DailyBriefBuilder.maxMarketLines)
    }

    func testDailyBriefIncludesMarketLines() {
        let brief = DailyBriefBuilder.build(
            profile: PersonalProfile(displayName: "Sam"),
            facts: [],
            events: [],
            marketLines: ["AAPL +1.2%", "2 of 3 watchlist up"],
            now: Date()
        )
        XCTAssertEqual(brief.marketLines.count, 2)
        XCTAssertTrue(brief.markdown.contains("Markets"))
        XCTAssertTrue(brief.markdown.contains("AAPL"))
    }

    func testHoldingPL() {
        let holding = HoldingInfo(symbol: "AAPL", shares: 10, avgCost: 100)
        XCTAssertEqual(holding.costBasis, 1000)
        XCTAssertEqual(holding.marketValue(price: 150), 1500)
        XCTAssertEqual(holding.unrealizedPL(price: 150), 500)
    }

    func testFridayPortfolioTemplateExists() {
        XCTAssertTrue(AutomationRecipe.templates.contains(where: { $0.title.contains("portfolio") }))
    }
}
