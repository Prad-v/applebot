import Foundation

// MARK: - Watchlist

/// Portable watchlist row (SwiftData maps to/from this).
public struct WatchlistItemInfo: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var symbol: String
    public var name: String
    public var groupTag: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        symbol: String,
        name: String = "",
        groupTag: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.symbol = Self.normalizeSymbol(symbol)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.groupTag = groupTag.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayLine: String {
        if name.isEmpty { return symbol }
        return "\(symbol) (\(name))"
    }

    public static func normalizeSymbol(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

// MARK: - Holdings

public struct HoldingInfo: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var symbol: String
    public var shares: Double
    public var avgCost: Double
    public var currency: String
    public var notes: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        symbol: String,
        shares: Double,
        avgCost: Double,
        currency: String = "USD",
        notes: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.symbol = WatchlistItemInfo.normalizeSymbol(symbol)
        self.shares = max(0, shares)
        self.avgCost = max(0, avgCost)
        self.currency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updatedAt = updatedAt
    }

    public var costBasis: Double { shares * avgCost }

    public func marketValue(price: Double) -> Double { shares * price }

    public func unrealizedPL(price: Double) -> Double { marketValue(price: price) - costBasis }

    public var displayLine: String {
        let sharesText = shares == floor(shares) ? String(Int(shares)) : String(format: "%.4g", shares)
        return "\(symbol): \(sharesText) shares @ \(String(format: "%.2f", avgCost)) \(currency)"
    }
}

// MARK: - Quote snapshot (cache / alerts / UI)

public struct StockQuoteSnapshot: Sendable, Equatable, Identifiable, Codable {
    public var symbol: String
    public var name: String?
    public var exchange: String?
    public var currency: String?
    public var price: Double
    public var previousClose: Double?
    public var dayHigh: Double?
    public var dayLow: Double?
    public var yearHigh: Double?
    public var yearLow: Double?
    public var asOf: Date?

    public var id: String { symbol }

    public init(
        symbol: String,
        name: String? = nil,
        exchange: String? = nil,
        currency: String? = nil,
        price: Double,
        previousClose: Double? = nil,
        dayHigh: Double? = nil,
        dayLow: Double? = nil,
        yearHigh: Double? = nil,
        yearLow: Double? = nil,
        asOf: Date? = nil
    ) {
        self.symbol = WatchlistItemInfo.normalizeSymbol(symbol)
        self.name = name
        self.exchange = exchange
        self.currency = currency
        self.price = price
        self.previousClose = previousClose
        self.dayHigh = dayHigh
        self.dayLow = dayLow
        self.yearHigh = yearHigh
        self.yearLow = yearLow
        self.asOf = asOf
    }

    public var change: Double? {
        guard let previousClose, previousClose != 0 else { return nil }
        return price - previousClose
    }

    public var changePercent: Double? {
        guard let previousClose, previousClose != 0, let change else { return nil }
        return change / previousClose * 100
    }

    public var summaryLine: String {
        var line = symbol
        if let name, !name.isEmpty { line += " (\(name))" }
        line += String(format: ": %.2f", price)
        if let currency, !currency.isEmpty { line += " \(currency)" }
        if let change, let percent = changePercent {
            let sign = change >= 0 ? "+" : ""
            line += String(format: " (%@%.2f, %@%.2f%%)", sign, change, sign, percent)
        }
        return line
    }
}

// MARK: - Alerts

public enum StockAlertKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case above
    case below
    case dayPercent
    case near52w
    case eventDate

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .above: return "Price above"
        case .below: return "Price below"
        case .dayPercent: return "Day move %"
        case .near52w: return "Near 52-week high/low"
        case .eventDate: return "Event / earnings date"
        }
    }
}

public struct StockAlertRuleInfo: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var symbol: String
    public var kind: StockAlertKind
    public var threshold: Double
    /// For `.eventDate`, seconds since 1970 of the reminder day (local noon).
    public var eventDate: Date?
    public var isEnabled: Bool
    public var lastFiredAt: Date?
    /// Minimum seconds between fires for the same rule.
    public var cooldownSeconds: TimeInterval
    public var notes: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        symbol: String,
        kind: StockAlertKind,
        threshold: Double,
        eventDate: Date? = nil,
        isEnabled: Bool = true,
        lastFiredAt: Date? = nil,
        cooldownSeconds: TimeInterval = 6 * 60 * 60,
        notes: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.symbol = WatchlistItemInfo.normalizeSymbol(symbol)
        self.kind = kind
        self.threshold = threshold
        self.eventDate = eventDate
        self.isEnabled = isEnabled
        self.lastFiredAt = lastFiredAt
        self.cooldownSeconds = max(60, cooldownSeconds)
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updatedAt = updatedAt
    }

    public var displayLine: String {
        switch kind {
        case .above: return "\(symbol) above \(String(format: "%.2f", threshold))"
        case .below: return "\(symbol) below \(String(format: "%.2f", threshold))"
        case .dayPercent: return "\(symbol) day move ≥ \(String(format: "%.1f", threshold))%"
        case .near52w: return "\(symbol) within \(String(format: "%.1f", threshold))% of 52-week extreme"
        case .eventDate:
            if let eventDate {
                return "\(symbol) event \(eventDate.formatted(date: .abbreviated, time: .omitted))"
            }
            return "\(symbol) event"
        }
    }
}

public struct StockAlertFire: Sendable, Equatable, Identifiable {
    public var id: UUID { ruleID }
    public var ruleID: UUID
    public var symbol: String
    public var title: String
    public var body: String
    public var firedAt: Date

    public init(ruleID: UUID, symbol: String, title: String, body: String, firedAt: Date = Date()) {
        self.ruleID = ruleID
        self.symbol = symbol
        self.title = title
        self.body = body
        self.firedAt = firedAt
    }
}

public enum StocksAlertEvaluator {
    /// Quiet hours: 22:00–07:00 local by default (skip price alerts; event-date still allowed).
    public static func isQuietHours(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 7
    }

    public static func evaluate(
        rules: [StockAlertRuleInfo],
        quotes: [String: StockQuoteSnapshot],
        now: Date = Date(),
        calendar: Calendar = .current,
        respectQuietHours: Bool = true
    ) -> [StockAlertFire] {
        var fires: [StockAlertFire] = []
        let quiet = respectQuietHours && isQuietHours(now, calendar: calendar)

        for rule in rules where rule.isEnabled {
            if let last = rule.lastFiredAt, now.timeIntervalSince(last) < rule.cooldownSeconds {
                continue
            }

            if rule.kind == .eventDate {
                guard let eventDate = rule.eventDate else { continue }
                if calendar.isDate(eventDate, inSameDayAs: now) {
                    fires.append(StockAlertFire(
                        ruleID: rule.id,
                        symbol: rule.symbol,
                        title: "\(rule.symbol) event today",
                        body: rule.notes.isEmpty
                            ? "You set an event reminder for \(rule.symbol). Quotes can be delayed. Not financial advice."
                            : rule.notes,
                        firedAt: now
                    ))
                }
                continue
            }

            if quiet { continue }
            guard let quote = quotes[rule.symbol] else { continue }

            switch rule.kind {
            case .above:
                if quote.price >= rule.threshold {
                    fires.append(fire(rule, quote: quote, detail: String(format: "Price %.2f is at or above %.2f", quote.price, rule.threshold), now: now))
                }
            case .below:
                if quote.price <= rule.threshold {
                    fires.append(fire(rule, quote: quote, detail: String(format: "Price %.2f is at or below %.2f", quote.price, rule.threshold), now: now))
                }
            case .dayPercent:
                if let percent = quote.changePercent, abs(percent) >= abs(rule.threshold) {
                    fires.append(fire(rule, quote: quote, detail: String(format: "Day move %.2f%% (threshold %.1f%%)", percent, rule.threshold), now: now))
                }
            case .near52w:
                let nearHigh = quote.yearHigh.map { high in
                    high > 0 && (high - quote.price) / high * 100 <= rule.threshold
                } ?? false
                let nearLow = quote.yearLow.map { low in
                    low > 0 && (quote.price - low) / low * 100 <= rule.threshold
                } ?? false
                if nearHigh || nearLow {
                    let which = nearHigh ? "52-week high" : "52-week low"
                    fires.append(fire(rule, quote: quote, detail: "Near \(which) (within \(String(format: "%.1f", rule.threshold))%)", now: now))
                }
            case .eventDate:
                break
            }
        }
        return fires
    }

    private static func fire(_ rule: StockAlertRuleInfo, quote: StockQuoteSnapshot, detail: String, now: Date) -> StockAlertFire {
        StockAlertFire(
            ruleID: rule.id,
            symbol: rule.symbol,
            title: "\(rule.symbol) alert",
            body: "\(detail). \(quote.summaryLine). Quotes can be delayed. Not financial advice.",
            firedAt: now
        )
    }

    /// Suggest price alerts from a quote (user must confirm).
    public static func suggestedRules(for quote: StockQuoteSnapshot) -> [StockAlertRuleInfo] {
        var rules: [StockAlertRuleInfo] = []
        if let high = quote.yearHigh, high > quote.price {
            rules.append(StockAlertRuleInfo(symbol: quote.symbol, kind: .above, threshold: (quote.price + high) / 2))
        }
        if let low = quote.yearLow, low < quote.price, low > 0 {
            rules.append(StockAlertRuleInfo(symbol: quote.symbol, kind: .below, threshold: (quote.price + low) / 2))
        }
        rules.append(StockAlertRuleInfo(symbol: quote.symbol, kind: .dayPercent, threshold: 5))
        rules.append(StockAlertRuleInfo(symbol: quote.symbol, kind: .near52w, threshold: 2))
        return rules
    }
}

// MARK: - Market session (US RTH heuristic)

public enum MarketSession: String, Sendable, Equatable {
    case preMarket
    case open
    case afterHours
    case closed

    public var displayName: String {
        switch self {
        case .preMarket: return "Pre-market"
        case .open: return "Market open"
        case .afterHours: return "After hours"
        case .closed: return "Market closed"
        }
    }

    /// US equity regular hours 9:30–16:00 Eastern; weekend = closed.
    public static func usEquity(at date: Date = Date(), timeZone: TimeZone = TimeZone(identifier: "America/New_York") ?? .current) -> MarketSession {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 { return .closed }
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let mins = hour * 60 + minute
        // 4:00–9:29 pre, 9:30–15:59 open, 16:00–19:59 after, else closed
        if mins >= 4 * 60 && mins < 9 * 60 + 30 { return .preMarket }
        if mins >= 9 * 60 + 30 && mins < 16 * 60 { return .open }
        if mins >= 16 * 60 && mins < 20 * 60 { return .afterHours }
        return .closed
    }
}

// MARK: - Context + insight

public enum StocksContextBudget {
    public static let maxTokens = 140

    public static let disclaimer =
        "Quotes can be delayed. Applebot is not a broker and does not give financial advice."

    public static func render(
        watchlist: [WatchlistItemInfo],
        holdings: [HoldingInfo] = [],
        quotes: [String: StockQuoteSnapshot] = [:],
        maxTokens: Int = maxTokens
    ) -> String? {
        guard !watchlist.isEmpty || !holdings.isEmpty else { return nil }
        var lines: [String] = ["Stocks context (on this iPhone only):"]
        if !watchlist.isEmpty {
            lines.append("- Watchlist:")
            for item in watchlist.prefix(12) {
                if let quote = quotes[item.symbol] {
                    lines.append("  • \(quote.summaryLine)")
                } else {
                    lines.append("  • \(item.displayLine)")
                }
            }
        }
        if !holdings.isEmpty {
            lines.append("- Holdings (user-entered, not broker-synced):")
            for holding in holdings.prefix(8) {
                if let quote = quotes[holding.symbol] {
                    let pl = holding.unrealizedPL(price: quote.price)
                    let sign = pl >= 0 ? "+" : ""
                    lines.append("  • \(holding.displayLine); mkt \(String(format: "%.2f", quote.price)); P&L \(sign)\(String(format: "%.2f", pl))")
                } else {
                    lines.append("  • \(holding.displayLine)")
                }
            }
        }
        lines.append("- \(disclaimer)")
        return TokenEstimator.truncate(lines.joined(separator: "\n"), toTokens: maxTokens)
    }

    /// Soft concentration note from holdings weights (educational).
    public static func concentrationLine(holdings: [HoldingInfo], quotes: [String: StockQuoteSnapshot]) -> String? {
        var values: [(String, Double)] = []
        var total = 0.0
        for holding in holdings {
            guard let price = quotes[holding.symbol]?.price, price > 0, holding.shares > 0 else { continue }
            let value = holding.marketValue(price: price)
            values.append((holding.symbol, value))
            total += value
        }
        guard total > 0, let top = values.max(by: { $0.1 < $1.1 }) else { return nil }
        let pct = top.1 / total * 100
        guard pct >= 35 else { return nil }
        return String(format: "%@ is about %.0f%% of listed holdings by market value (on-device estimate).", top.0, pct)
    }
}

public enum StocksAskKind: String, Sendable {
    case movers
    case watchlist
    case holdings
    case whyMoved
}

public enum StocksInsightBuilder {
    public static let userFacingDisclaimer =
        "Quotes can be delayed up to about 15 minutes. Not financial advice. "
        + "Applebot is not a broker and does not recommend buying or selling."

    public static func narrativeRequest(
        quotes: [StockQuoteSnapshot],
        holdings: [HoldingInfo] = [],
        concentration: String? = nil,
        session: MarketSession = .closed
    ) -> LLMRequest {
        var prompt = "Market session (US equity heuristic): \(session.displayName).\n"
        if quotes.isEmpty {
            prompt += "Watchlist quotes: none loaded.\n"
        } else {
            prompt += "Watchlist quotes:\n"
            for quote in quotes.prefix(12) {
                prompt += "- \(quote.summaryLine)\n"
                if let low = quote.dayLow, let high = quote.dayHigh {
                    prompt += String(format: "  Day range %.2f–%.2f\n", low, high)
                }
            }
        }
        if !holdings.isEmpty {
            prompt += "Holdings (user-entered):\n"
            for holding in holdings.prefix(8) {
                prompt += "- \(holding.displayLine)\n"
            }
        }
        if let concentration {
            prompt += "Concentration note: \(concentration)\n"
        }

        return LLMRequest(
            instructions: "You write a short market awareness note for a private on-device Stocks tab. "
                + "Use only the prices and holdings provided. Never invent prices. "
                + "Write 1–2 short paragraphs: summarize movers on the watchlist; "
                + "if holdings exist, mention rough P&L tone without telling the user to buy or sell. "
                + "If a concentration note is provided, mention it gently as awareness only. "
                + "Never recommend a trade. End with exactly this line:\n"
                + "DISCLAIMER: \(userFacingDisclaimer)",
            prompt: TokenEstimator.truncate(prompt, toTokens: 700)
        )
    }

    public static func askPrompt(
        kind: StocksAskKind,
        quotes: [StockQuoteSnapshot],
        holdings: [HoldingInfo] = []
    ) -> String {
        switch kind {
        case .movers:
            let lines = quotes.prefix(8).map(\.summaryLine).joined(separator: "; ")
            return "Summarize how my watchlist is moving today"
                + (lines.isEmpty ? "." : ": \(lines).")
                + " Keep it short. Quotes may be delayed. Not financial advice."
        case .watchlist:
            let symbols = quotes.map(\.symbol)
            if symbols.isEmpty {
                return "I haven't saved a watchlist in Applebot yet. How should I track a few tickers privately on-device? Not financial advice."
            }
            return "Walk through my Applebot watchlist (\(symbols.joined(separator: ", "))) with today's prices if tools can look them up. Not financial advice."
        case .holdings:
            if holdings.isEmpty {
                return "I haven't entered holdings in Applebot yet. Explain how on-device cost-basis tracking works without broker sync. Not financial advice."
            }
            let lines = holdings.prefix(8).map(\.displayLine).joined(separator: "; ")
            return "Summarize my Applebot holdings P&L using live quotes if available: \(lines). Do not tell me to buy or sell. Not financial advice."
        case .whyMoved:
            let top = quotes.sorted { abs($0.changePercent ?? 0) > abs($1.changePercent ?? 0) }.first
            let symbol = top?.symbol ?? quotes.first?.symbol ?? "my top mover"
            return "What might be driving \(symbol)'s move today? Use stock_quote and web search if available. "
                + "Be cautious, cite only tool results, and do not recommend trades. Not financial advice."
        }
    }
}

/// Pending confirm card: model or UI suggested a watchlist add.
public struct PendingWatchlistAdd: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var symbol: String
    public var name: String
    public var reason: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        symbol: String,
        name: String = "",
        reason: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.symbol = WatchlistItemInfo.normalizeSymbol(symbol)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
    }
}

/// Pending confirm card: suggested alert rule.
public struct PendingStockAlert: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var rule: StockAlertRuleInfo
    public var reason: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        rule: StockAlertRuleInfo,
        reason: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.rule = rule
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
    }
}
