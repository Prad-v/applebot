import Foundation
import LLMKit

/// Latest prices for stocks, ETFs, indices and crypto, from Yahoo Finance's public chart endpoint
/// (no account, no API key).
///
/// The endpoint is unofficial and Yahoo may change or limit it; failures surface as a plain error and
/// the model is told not to guess a price. Only the ticker or company name the user asked about
/// leaves the device. Quotes can be delayed, and nothing here is financial advice.
public struct StocksConnector: Connector {
    public let id = "stocks"
    public let displayName = "Stocks"
    public let summary = "Latest prices for stocks, funds, indices and crypto."
    public let symbolName = "chart.line.uptrend.xyaxis"
    public let dataNote = "Sends only the ticker or company you ask about to Yahoo Finance. No account, and nothing else leaves this iPhone. Quotes can be delayed up to 15 minutes. Not financial advice."
    public let hasAccount = false
    public var usesNetwork: Bool { true }

    static let chartURL = "https://query1.finance.yahoo.com/v8/finance/chart/"
    static let searchURL = "https://query1.finance.yahoo.com/v1/finance/search"
    static let service = "Yahoo Finance"

    private let http: HTTPClient
    private let calendar: Calendar

    public init(http: HTTPClient = URLSessionHTTPClient(), calendar: Calendar = .current) {
        self.http = http
        self.calendar = calendar
    }

    public func status() async -> ConnectorStatus { .connected(account: nil) }
    public func connect() async throws {}
    public func disconnect() async {}

    public func tools() -> [ToolSpec] { [quoteTool] }

    // MARK: Tool

    private var quoteTool: ToolSpec {
        let http = self.http, calendar = self.calendar
        return ToolSpec(
            name: "stock_quote",
            description: "Get the latest price of a stock, ETF, index or cryptocurrency and how much it changed since the previous close. Use for any question about a share price, a market index or a coin's price. Pass a ticker such as AAPL, TSLA, ^GSPC or BTC-USD, or a company name.",
            parameters: [
                ToolParameter("symbol", "Ticker symbol (AAPL, MSFT, ^GSPC, BTC-USD, VOD.L) or a company name such as 'Apple'."),
            ],
            label: "Looking up the price",
            handler: { arguments in
                guard let raw = arguments.string("symbol") else {
                    throw ConnectorError.invalidArgument("A ticker or company name is required, for example AAPL.")
                }
                let query = String(raw.prefix(80))
                return try await Self.lookup(query, http: http, calendar: calendar)
            }
        )
    }

    // MARK: Lookup

    static func lookup(_ query: String, http: HTTPClient, calendar: Calendar) async throws -> String {
        if looksLikeTicker(query), let quote = try await chart(symbol: query.uppercased(), http: http) {
            return render(quote, calendar: calendar)
        }
        // A company name, or a ticker Yahoo does not know: let Yahoo's search pick the symbol.
        guard let symbol = try await search(query, http: http),
              let quote = try await chart(symbol: symbol, http: http) else {
            throw ConnectorError.invalidArgument(
                "No stock, fund, index or coin matched \"\(query)\". Try its ticker symbol, like AAPL."
            )
        }
        return render(quote, calendar: calendar)
    }

    /// Tickers have no spaces and are at most five plain letters; longer words are company names.
    static func looksLikeTicker(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 12 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-^="))
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let lettersOnly = text.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
        return !(lettersOnly && text.count > 5)
    }

    private struct SearchResponse: Decodable {
        struct Item: Decodable { var symbol: String? }
        var quotes: [Item]?
    }

    static func search(_ query: String, http: HTTPClient) async throws -> String? {
        let url = try LiveData.url(searchURL, ["q": query, "quotesCount": "3", "newsCount": "0", "listsCount": "0"])
        let data = try await LiveData.fetch(http, url, service: service)
        let response = try LiveData.decode(SearchResponse.self, from: data, service: service)
        return response.quotes?.compactMap(\.symbol).first
    }

    struct Quote: Equatable {
        var symbol: String
        var name: String?
        var exchange: String?
        var currency: String?
        var price: Double
        var previousClose: Double?
        var dayHigh: Double?
        var dayLow: Double?
        var yearHigh: Double?
        var yearLow: Double?
        var time: Date?
    }

    private struct ChartResponse: Decodable {
        struct Chart: Decodable {
            struct Result: Decodable {
                struct Meta: Decodable {
                    var symbol: String?
                    var currency: String?
                    var exchangeName: String?
                    var fullExchangeName: String?
                    var longName: String?
                    var shortName: String?
                    var regularMarketPrice: Double?
                    var chartPreviousClose: Double?
                    var previousClose: Double?
                    var regularMarketTime: Double?
                    var regularMarketDayHigh: Double?
                    var regularMarketDayLow: Double?
                    var fiftyTwoWeekHigh: Double?
                    var fiftyTwoWeekLow: Double?
                }
                struct Indicators: Decodable {
                    struct Series: Decodable { var close: [Double?]? }
                    var quote: [Series]?
                }
                var meta: Meta
                var indicators: Indicators?
            }
            struct Failure: Decodable { var code: String?; var description: String? }
            var result: [Result]?
            var error: Failure?
        }
        var chart: Chart
    }

    /// The quote for an exact symbol, or nil when Yahoo does not know it.
    static func chart(symbol: String, http: HTTPClient) async throws -> Quote? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? symbol
        let url = try LiveData.url(chartURL + encoded, ["interval": "1d", "range": "5d"])
        let data: Data
        do {
            data = try await LiveData.fetch(http, url, service: service)
        } catch ConnectorError.http(let status, _) where status == 404 {
            return nil
        }
        let response = try LiveData.decode(ChartResponse.self, from: data, service: service)
        guard response.chart.error == nil, let result = response.chart.result?.first,
              let price = result.meta.regularMarketPrice else { return nil }
        let meta = result.meta

        // `chartPreviousClose` is the close before the whole 5-day window, so yesterday's close comes
        // from the daily candles instead: the one before the latest candle.
        let closes = (result.indicators?.quote?.first?.close ?? []).compactMap { $0 }
        let previous = closes.count >= 2 ? closes[closes.count - 2] : (meta.previousClose ?? meta.chartPreviousClose)

        return Quote(
            symbol: meta.symbol ?? symbol,
            name: meta.longName ?? meta.shortName,
            exchange: meta.fullExchangeName ?? meta.exchangeName,
            currency: meta.currency,
            price: price,
            previousClose: previous,
            dayHigh: meta.regularMarketDayHigh,
            dayLow: meta.regularMarketDayLow,
            yearHigh: meta.fiftyTwoWeekHigh,
            yearLow: meta.fiftyTwoWeekLow,
            time: meta.regularMarketTime.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: Output

    static func render(_ quote: Quote, calendar: Calendar) -> String {
        let decimals = abs(quote.price) < 1 ? 4 : 2
        func money(_ value: Double) -> String { LiveData.number(value, decimals: decimals) }

        var title = quote.symbol
        if let name = quote.name, !name.isEmpty { title += " (\(name))" }
        if let exchange = quote.exchange, !exchange.isEmpty { title += ", \(exchange)" }
        let currency = quote.currency.map { " \($0)" } ?? ""
        var lines = ["\(title): \(money(quote.price))\(currency)"]

        if let previous = quote.previousClose, previous != 0 {
            let change = quote.price - previous
            let percent = change / previous * 100
            let direction = change > 0 ? "up" : (change < 0 ? "down" : "unchanged")
            lines[0] += change == 0
                ? ", unchanged from the previous close of \(money(previous))."
                : ", \(direction) \(money(abs(change))) (\(change > 0 ? "+" : "-")\(LiveData.number(abs(percent), decimals: 2))%) from the previous close of \(money(previous))."
        } else {
            lines[0] += "."
        }

        if let low = quote.dayLow, let high = quote.dayHigh {
            lines.append("Day range \(money(low)) to \(money(high)).")
        }
        if let low = quote.yearLow, let high = quote.yearHigh {
            lines.append("52-week range \(money(low)) to \(money(high)).")
        }
        var footer = "Quotes can be delayed up to 15 minutes. Source: Yahoo Finance."
        if let time = quote.time { footer = "As of \(DateInput.format(time, calendar: calendar)). " + footer }
        lines.append(footer)
        return lines.joined(separator: "\n")
    }
}
