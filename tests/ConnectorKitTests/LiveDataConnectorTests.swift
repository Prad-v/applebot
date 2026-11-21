import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMKit
@testable import ConnectorKit

// Weather, Stocks and Web search: the connectors that look up live public data. Every test runs
// against a scripted HTTPClient, so nothing here touches the network.

private func body(_ text: String) -> Data { Data(text.utf8) }

private func tool(_ name: String, in connector: some Connector) throws -> ToolSpec {
    try XCTUnwrap(connector.tools().first { $0.name == name })
}

private func assertFails(
    _ expected: ConnectorError, file: StaticString = #filePath, line: UInt = #line,
    _ work: () async throws -> Void
) async {
    do {
        try await work()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as ConnectorError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}

// MARK: - Weather

final class WeatherConnectorTests: XCTestCase {
    private let paris = """
    {"results":[{"name":"Paris","latitude":48.85341,"longitude":2.3488,"country":"France","country_code":"FR","admin1":"Île-de-France"}]}
    """

    private let forecast = """
    {"timezone":"Europe/Paris",
     "current":{"time":"2026-11-21T09:30","temperature_2m":8.4,"apparent_temperature":6.1,"relative_humidity_2m":82,
                "precipitation":0.2,"weather_code":61,"wind_speed_10m":12.3},
     "daily":{"time":["2026-11-21","2026-11-22","2026-11-23"],"weather_code":[61,3,0],
              "temperature_2m_max":[10.2,11.0,9.4],"temperature_2m_min":[6.1,5.0,2.2],
              "precipitation_probability_max":[60,10,null]}}
    """

    private func client(geocode: String? = nil, forecast: String? = nil) -> MockHTTPClient {
        let geocode = geocode ?? paris, forecast = forecast ?? self.forecast
        return MockHTTPClient { request in
            switch request.url?.host {
            case "geocoding-api.open-meteo.com": return (200, body(geocode))
            case "api.open-meteo.com": return (200, body(forecast))
            default: return (404, Data())
            }
        }
    }

    func testDescribesItselfAsAKeylessOptInNetworkConnector() async throws {
        let connector = WeatherConnector(http: client(), imperial: false)
        XCTAssertEqual(connector.id, "weather")
        XCTAssertFalse(connector.hasAccount)
        XCTAssertTrue(connector.usesNetwork)
        let status = await connector.status()
        XCTAssertEqual(status, .connected(account: nil))
        XCTAssertEqual(connector.tools().map(\.name), ["weather_forecast"])
        XCTAssertFalse(try tool("weather_forecast", in: connector).requiresApproval, "reading the weather needs no approval")
    }

    func testCurrentConditionsAndForecast() async throws {
        let mock = client()
        let connector = WeatherConnector(http: mock, imperial: false)
        let output = try await tool("weather_forecast", in: connector).handler(ToolArguments(["location": "Paris, France"]))

        XCTAssertEqual(output, """
        Weather for Paris, Île-de-France, France. Local time 2026-11-21 09:30.
        Now: 8°C (feels like 6°C), light rain, humidity 82%, wind 12 km/h, precipitation 0.2 mm.
        Forecast:
        - Sat 2026-11-21: 6 to 10°C, light rain, 60% chance of precipitation
        - Sun 2026-11-22: 5 to 11°C, overcast, 10% chance of precipitation
        - Mon 2026-11-23: 2 to 9°C, clear sky
        Source: Open-Meteo.
        """)

        let geocode = try XCTUnwrap(mock.requests.first).queryDictionary
        XCTAssertEqual(geocode["name"], "Paris", "the country is a hint, not part of the name that is searched")
        let forecastQuery = try XCTUnwrap(mock.requests.last).queryDictionary
        XCTAssertEqual(forecastQuery["latitude"], "48.85341")
        XCTAssertEqual(forecastQuery["forecast_days"], "3")
        XCTAssertEqual(forecastQuery["temperature_unit"], "celsius")
        XCTAssertEqual(forecastQuery["timezone"], "auto")
    }

    func testImperialUnitsFollowTheQuestionOrTheDeviceRegion() async throws {
        let us = client()
        let output = try await tool("weather_forecast", in: WeatherConnector(http: us, imperial: true))
            .handler(ToolArguments(["location": "Paris"]))
        let query = try XCTUnwrap(us.requests.last).queryDictionary
        XCTAssertEqual(query["temperature_unit"], "fahrenheit")
        XCTAssertEqual(query["wind_speed_unit"], "mph")
        XCTAssertEqual(query["precipitation_unit"], "inch")
        XCTAssertTrue(output.contains("°F") && output.contains("mph"))

        // An explicit request beats the device default, in both directions.
        let metric = client()
        _ = try await tool("weather_forecast", in: WeatherConnector(http: metric, imperial: true))
            .handler(ToolArguments(["location": "Paris", "units": "Celsius"]))
        XCTAssertEqual(try XCTUnwrap(metric.requests.last).queryDictionary["temperature_unit"], "celsius")

        let imperial = client()
        _ = try await tool("weather_forecast", in: WeatherConnector(http: imperial, imperial: false))
            .handler(ToolArguments(["location": "Paris", "units": "imperial"]))
        XCTAssertEqual(try XCTUnwrap(imperial.requests.last).queryDictionary["temperature_unit"], "fahrenheit")
    }

    func testDaysAreClamped() async throws {
        for (given, expected) in [("30", "7"), ("0", "1"), ("-4", "1"), ("2", "2")] {
            let mock = client()
            _ = try await tool("weather_forecast", in: WeatherConnector(http: mock, imperial: false))
                .handler(ToolArguments(["location": "Paris", "days": given]))
            XCTAssertEqual(try XCTUnwrap(mock.requests.last).queryDictionary["forecast_days"], expected, given)
        }
    }

    func testHintPicksTheRightPlaceWhenNamesCollide() {
        let places = [
            WeatherConnector.Place(name: "Paris", latitude: 33.66, longitude: -95.55, country: "United States", countryCode: "US", admin1: "Texas"),
            WeatherConnector.Place(name: "Paris", latitude: 48.85, longitude: 2.35, country: "France", countryCode: "FR", admin1: "Île-de-France"),
        ]
        XCTAssertEqual(WeatherConnector.choose(places, hint: nil)?.country, "United States", "most populous match comes first")
        XCTAssertEqual(WeatherConnector.choose(places, hint: "France")?.country, "France")
        XCTAssertEqual(WeatherConnector.choose(places, hint: "fr")?.country, "France", "country codes match exactly")
        XCTAssertEqual(WeatherConnector.choose(places, hint: "Paris, Texas")?.admin1, "Texas")
        XCTAssertEqual(WeatherConnector.choose(places, hint: "Atlantis")?.country, "United States", "an unmatched hint falls back to the best match")
        XCTAssertNil(WeatherConnector.choose([], hint: "France"))
    }

    func testUnknownPlaceAsksForMoreDetail() async throws {
        let connector = WeatherConnector(http: client(geocode: "{}"), imperial: false)
        let weather = try tool("weather_forecast", in: connector)
        await assertFails(.invalidArgument("Couldn't find a place called \"Atlantis\". Try the city with its country, like \"Paris, France\".")) {
            _ = try await weather.handler(ToolArguments(["location": "Atlantis"]))
        }
    }

    func testMissingOrTooShortLocationIsRejectedWithoutANetworkCall() async throws {
        let mock = client()
        let weather = try tool("weather_forecast", in: WeatherConnector(http: mock, imperial: false))
        for location in [nil, "", "   ", "x", ", France"] {
            await assertFails(.invalidArgument("A location is required, for example 'Paris, France'.")) {
                _ = try await weather.handler(ToolArguments(location.map { ["location": $0] } ?? [:]))
            }
        }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testOfflineBecomesAPlainMessage() async throws {
        let offline = MockHTTPClient { _ in throw URLError(.notConnectedToInternet) }
        let weather = try tool("weather_forecast", in: WeatherConnector(http: offline, imperial: false))
        await assertFails(.unexpectedResponse("Couldn't reach Open-Meteo. Check the internet connection and try again.")) {
            _ = try await weather.handler(ToolArguments(["location": "Paris"]))
        }
    }

    func testServerErrorsAndGarbageAreReported() async throws {
        let down = MockHTTPClient { _ in (503, body("{\"reason\":\"maintenance\"}")) }
        let weather = try tool("weather_forecast", in: WeatherConnector(http: down, imperial: false))
        do {
            _ = try await weather.handler(ToolArguments(["location": "Paris"]))
            XCTFail("expected an error")
        } catch let ConnectorError.http(status, _) {
            XCTAssertEqual(status, 503)
        }

        let garbage = client(forecast: "not json")
        let broken = try tool("weather_forecast", in: WeatherConnector(http: garbage, imperial: false))
        await assertFails(.unexpectedResponse("Open-Meteo sent a reply Applebot couldn't read.")) {
            _ = try await broken.handler(ToolArguments(["location": "Paris"]))
        }
    }

    func testPartialDataStillRenders() async throws {
        let sparse = client(forecast: "{\"current\":{\"time\":\"2026-11-21T09:30\",\"temperature_2m\":-0.3}}")
        let output = try await tool("weather_forecast", in: WeatherConnector(http: sparse, imperial: false))
            .handler(ToolArguments(["location": "Paris"]))
        XCTAssertTrue(output.contains("Now: 0°C"), "-0.3 must not print as -0: \(output)")
        XCTAssertFalse(output.contains("Forecast:"))
    }

    func testResultIsMarkedUntrustedAndFailuresTellTheModelNotToGuess() async throws {
        let connector = WeatherConnector(http: client(), imperial: false)
        let guarded = ToolGuard(approver: nil).wrap(connector.tools())
        let ok = try await guarded[0].handler(ToolArguments(["location": "Paris"]))
        XCTAssertTrue(ok.hasPrefix(ToolGuard.untrustedPrefix))

        let offline = WeatherConnector(http: MockHTTPClient { _ in throw URLError(.timedOut) }, imperial: false)
        let failed = try await ToolGuard(approver: nil).wrap(offline.tools())[0].handler(ToolArguments(["location": "Paris"]))
        XCTAssertTrue(failed.contains("do not guess"))
    }

    func testWeatherCodesAndUnitWords() {
        XCTAssertEqual(WeatherConnector.describe(0), "clear sky")
        XCTAssertEqual(WeatherConnector.describe(95), "thunderstorm")
        XCTAssertEqual(WeatherConnector.describe(12345), "unsettled")
        XCTAssertEqual(WeatherConnector.wantsImperial("Fahrenheit"), true)
        XCTAssertEqual(WeatherConnector.wantsImperial("metric"), false)
        XCTAssertNil(WeatherConnector.wantsImperial("kelvin"))
        XCTAssertNil(WeatherConnector.wantsImperial(nil))
    }
}

// MARK: - Stocks

final class StocksConnectorTests: XCTestCase, @unchecked Sendable {
    private func chart(
        symbol: String = "AAPL", name: String = "Apple Inc.", price: Double = 189.3,
        closes: String = "[186.0,188.1,189.3]", currency: String = "USD"
    ) -> String {
        """
        {"chart":{"result":[{"meta":{"symbol":"\(symbol)","currency":"\(currency)","exchangeName":"NMS",
          "fullExchangeName":"NasdaqGS","longName":"\(name)","regularMarketPrice":\(price),"chartPreviousClose":170.0,
          "regularMarketTime":1795000000,"regularMarketDayHigh":190.2,"regularMarketDayLow":187.5,
          "fiftyTwoWeekHigh":199.62,"fiftyTwoWeekLow":164.08},
          "indicators":{"quote":[{"close":\(closes)}]}}],"error":null}}
        """
    }

    private let notFound = "{\"chart\":{\"result\":null,\"error\":{\"code\":\"Not Found\",\"description\":\"No data found\"}}}"

    private func quote(_ symbol: String, via client: MockHTTPClient) async throws -> String {
        try await tool("stock_quote", in: StocksConnector(http: client, calendar: utcCalendar()))
            .handler(ToolArguments(["symbol": symbol]))
    }

    func testDescribesItselfAsAKeylessOptInNetworkConnector() async throws {
        let connector = StocksConnector(http: MockHTTPClient { _ in (404, Data()) })
        XCTAssertEqual(connector.id, "stocks")
        XCTAssertFalse(connector.hasAccount)
        XCTAssertTrue(connector.usesNetwork)
        let status = await connector.status()
        XCTAssertEqual(status, .connected(account: nil))
        XCTAssertEqual(connector.tools().map(\.name), ["stock_quote"])
        XCTAssertFalse(connector.tools()[0].requiresApproval)
    }

    func testQuoteForATickerShowsPriceChangeAndRanges() async throws {
        let mock = MockHTTPClient { _ in (200, body(self.chart())) }
        let output = try await quote("aapl", via: mock)

        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "AAPL (Apple Inc.), NasdaqGS: 189.30 USD, up 1.20 (+0.64%) from the previous close of 188.10.")
        XCTAssertEqual(lines[1], "Day range 187.50 to 190.20.")
        XCTAssertEqual(lines[2], "52-week range 164.08 to 199.62.")
        XCTAssertTrue(lines[3].hasPrefix("As of ") && lines[3].hasSuffix("Quotes can be delayed up to 15 minutes. Source: Yahoo Finance."), lines[3])

        XCTAssertEqual(mock.requests.count, 1, "a ticker needs no symbol search")
        XCTAssertEqual(mock.requests[0].url?.path, "/v8/finance/chart/AAPL", "tickers are upper-cased")
    }

    func testPreviousCloseComesFromYesterdaysCandleNotTheFiveDayWindow() async throws {
        // chartPreviousClose (170) is the close before the whole window and would show a bogus +11%.
        let mock = MockHTTPClient { _ in (200, body(self.chart(closes: "[186.0,null,188.1,189.3]"))) }
        let output = try await quote("AAPL", via: mock)
        XCTAssertTrue(output.contains("previous close of 188.10"), output)
        XCTAssertFalse(output.contains("170"))
    }

    func testFallsBackToMetaWhenThereIsOnlyOneCandle() async throws {
        let mock = MockHTTPClient { _ in (200, body(self.chart(closes: "[189.3]"))) }
        let output = try await quote("AAPL", via: mock)
        XCTAssertTrue(output.contains("previous close of 170.00"), output)
    }

    func testDownwardMoveUnchangedAndMissingPreviousClose() async throws {
        let down = MockHTTPClient { _ in (200, body(self.chart(price: 99.0, closes: "[100.0,99.0]"))) }
        let downText = try await quote("AAPL", via: down)
        XCTAssertTrue(downText.contains("99.00 USD, down 1.00 (-1.00%) from the previous close of 100.00."), downText)

        let flat = MockHTTPClient { _ in (200, body(self.chart(price: 100.0, closes: "[100.0,100.0]"))) }
        let flatText = try await quote("AAPL", via: flat)
        XCTAssertTrue(flatText.contains("unchanged from the previous close of 100.00."), flatText)

        let none = MockHTTPClient { _ in (200, body(self.chart(closes: "null").replacingOccurrences(of: "\"chartPreviousClose\":170.0,", with: ""))) }
        let noneText = try await quote("AAPL", via: none)
        XCTAssertTrue(noneText.hasPrefix("AAPL (Apple Inc.), NasdaqGS: 189.30 USD.\n"), noneText)
    }

    func testCheapCoinsKeepFourDecimals() async throws {
        let mock = MockHTTPClient { _ in (200, body(self.chart(symbol: "SHIB-USD", name: "Shiba Inu", price: 0.1234, closes: "[0.12,0.1234]"))) }
        let output = try await quote("SHIB-USD", via: mock)
        XCTAssertTrue(output.contains("0.1234 USD, up 0.0034 (+2.83%)"), output)
    }

    func testCompanyNameIsResolvedThroughSearch() async throws {
        let mock = MockHTTPClient { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/chart/APPLE") { return (404, body(self.notFound)) }
            if path.hasSuffix("/finance/search") { return (200, body("{\"quotes\":[{\"symbol\":\"AAPL\"}]}")) }
            if path.hasSuffix("/chart/AAPL") { return (200, body(self.chart())) }
            return (500, Data())
        }
        let output = try await quote("Apple", via: mock)
        XCTAssertTrue(output.hasPrefix("AAPL (Apple Inc.)"))
        XCTAssertEqual(mock.requests.map { $0.url?.path }, [
            "/v8/finance/chart/APPLE", "/v1/finance/search", "/v8/finance/chart/AAPL",
        ])
        XCTAssertEqual(mock.requests[1].queryDictionary["q"], "Apple")
    }

    func testMultiWordNamesGoStraightToSearch() async throws {
        let mock = MockHTTPClient { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/finance/search") { return (200, body("{\"quotes\":[{\"symbol\":\"MSFT\"}]}")) }
            return (200, body(self.chart(symbol: "MSFT", name: "Microsoft Corporation")))
        }
        let output = try await quote("Microsoft Corporation", via: mock)
        XCTAssertTrue(output.hasPrefix("MSFT (Microsoft Corporation)"))
        XCTAssertEqual(mock.requests.map { $0.url?.path }, ["/v1/finance/search", "/v8/finance/chart/MSFT"])
    }

    func testIndexSymbolsAreEscapedInThePath() async throws {
        let mock = MockHTTPClient { _ in (200, body(self.chart(symbol: "^GSPC", name: "S&P 500"))) }
        _ = try await quote("^GSPC", via: mock)
        XCTAssertTrue(try XCTUnwrap(mock.requests.first?.url?.absoluteString).contains("/chart/%5EGSPC?"))
    }

    func testUnknownSymbolSaysSoInsteadOfGuessing() async throws {
        let mock = MockHTTPClient { request in
            if request.url?.path.hasSuffix("/finance/search") == true { return (200, body("{\"quotes\":[]}")) }
            return (404, body(self.notFound))
        }
        await assertFails(.invalidArgument("No stock, fund, index or coin matched \"ZZZZ\". Try its ticker symbol, like AAPL.")) {
            _ = try await quote("ZZZZ", via: mock)
        }
        // Yahoo can also answer 200 with an error object.
        let soft = MockHTTPClient { request in
            if request.url?.path.hasSuffix("/finance/search") == true { return (200, body("{}")) }
            return (200, body(self.notFound))
        }
        await assertFails(.invalidArgument("No stock, fund, index or coin matched \"ZZZZ\". Try its ticker symbol, like AAPL.")) {
            _ = try await quote("ZZZZ", via: soft)
        }
    }

    func testRateLimitsAndOutagesPropagate() async throws {
        let limited = MockHTTPClient { _ in (429, body("Too Many Requests")) }
        do {
            _ = try await quote("AAPL", via: limited)
            XCTFail("expected an error")
        } catch let ConnectorError.http(status, _) {
            XCTAssertEqual(status, 429)
        }
    }

    func testBlankSymbolIsRejectedWithoutANetworkCall() async throws {
        let mock = MockHTTPClient { _ in (200, body(self.chart())) }
        let stocks = try tool("stock_quote", in: StocksConnector(http: mock))
        await assertFails(.invalidArgument("A ticker or company name is required, for example AAPL.")) {
            _ = try await stocks.handler(ToolArguments(["symbol": "  "]))
        }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testTickerHeuristic() {
        for ticker in ["AAPL", "BRK-B", "VOD.L", "^GSPC", "BTC-USD", "EURUSD=X", "7203.T", "F"] {
            XCTAssertTrue(StocksConnector.looksLikeTicker(ticker), ticker)
        }
        for name in ["Microsoft", "Apple Inc", "", "Berkshire Hathaway B", "a/b", "AAAAAAAAAAAAAA"] {
            XCTAssertFalse(StocksConnector.looksLikeTicker(name), name)
        }
    }
}

// MARK: - Web search

final class WebSearchConnectorTests: XCTestCase, @unchecked Sendable {
    private let results = """
    {"web":{"results":[
      {"title":"Fed holds <strong>rates</strong> steady","url":"https://www.reuters.com/markets/fed",
       "description":"The Federal Reserve &amp; its chair said <strong>rates</strong> stay   unchanged.","age":"2 hours ago"},
      {"title":"Other","url":"https://apnews.com/x","description":"Second."}]}}
    """

    private func connector(_ client: MockHTTPClient, key: String = "test-key") -> WebSearchConnector {
        WebSearchConnector(configuration: WebSearchConfiguration(apiKey: key), http: client)
    }

    func testKeyValidation() {
        XCTAssertNil(WebSearchConfiguration(apiKey: ""))
        XCTAssertNil(WebSearchConfiguration(apiKey: "   "))
        XCTAssertNil(WebSearchConfiguration(apiKey: "$(BRAVE_API_KEY)"), "an unexpanded build placeholder is not a key")
        XCTAssertEqual(WebSearchConfiguration(apiKey: "  abc123 \n")?.apiKey, "abc123")
    }

    func testWithoutAKeyItExplainsWhatIsMissingAndOffersNoTools() async {
        let connector = WebSearchConnector(configuration: nil)
        let status = await connector.status()
        guard case .unavailable(let why) = status else { return XCTFail("expected unavailable, got \(status)") }
        XCTAssertTrue(why.contains("BRAVE_API_KEY"))
        XCTAssertTrue(connector.tools().isEmpty)
        do {
            try await connector.connect()
            XCTFail("connect must fail without a key")
        } catch {
            XCTAssertTrue((error as? ConnectorError).map { if case .notConfigured = $0 { true } else { false } } ?? false)
        }
    }

    func testAnUnconfiguredConnectorNeverContributesToolsEvenWhenSwitchedOn() async {
        let registry = ConnectorRegistry(connectors: [WebSearchConnector(configuration: nil)])
        await registry.setEnabled("web_search", true)
        let tools = await registry.activeTools()
        XCTAssertTrue(tools.isEmpty)
    }

    func testConfiguredConnectorIsConnectedAndOptIn() async {
        let connector = connector(MockHTTPClient { _ in (200, body(self.results)) })
        let status = await connector.status()
        XCTAssertEqual(status, .connected(account: nil))
        XCTAssertTrue(connector.usesNetwork)
        XCTAssertFalse(connector.hasAccount)
        XCTAssertEqual(connector.tools().map(\.name), ["web_search"])
        XCTAssertFalse(connector.tools()[0].requiresApproval)

        let registry = ConnectorRegistry(connectors: [connector])
        let before = await registry.activeTools()
        XCTAssertTrue(before.isEmpty, "off until the user switches it on")
        await registry.setEnabled("web_search", true)
        let after = await registry.activeTools()
        XCTAssertEqual(after.map(\.name), ["web_search"])
    }

    func testResultsAreCompactAndFreeOfMarkup() async throws {
        let mock = MockHTTPClient { _ in (200, body(self.results)) }
        let output = try await tool("web_search", in: connector(mock)).handler(ToolArguments(["query": "Fed rates"]))
        XCTAssertEqual(output, """
        Web results for "Fed rates" (Brave Search):
        1. Fed holds rates steady | reuters.com | 2 hours ago
           The Federal Reserve & its chair said rates stay unchanged.
        2. Other | apnews.com
           Second.
        """)

        let request = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "test-key")
        XCTAssertEqual(request.url?.host, "api.search.brave.com")
        let query = request.queryDictionary
        XCTAssertEqual(query["q"], "Fed rates")
        XCTAssertEqual(query["count"], "3")
        XCTAssertEqual(query["text_decorations"], "false")
        XCTAssertNil(query["freshness"])
    }

    func testLimitIsClampedAndRecencyMapsToBraveFreshness() async throws {
        for (given, expected) in [("99", "5"), ("0", "1"), ("2", "2")] {
            let mock = MockHTTPClient { _ in (200, body(self.results)) }
            _ = try await tool("web_search", in: connector(mock)).handler(ToolArguments(["query": "x", "limit": given]))
            XCTAssertEqual(try XCTUnwrap(mock.requests.first).queryDictionary["count"], expected, given)
        }
        for (given, expected) in [("day", "pd"), ("Week", "pw"), ("month", "pm"), ("year", "py")] {
            let mock = MockHTTPClient { _ in (200, body(self.results)) }
            _ = try await tool("web_search", in: connector(mock)).handler(ToolArguments(["query": "x", "recency": given]))
            XCTAssertEqual(try XCTUnwrap(mock.requests.first).queryDictionary["freshness"], expected, given)
        }
        XCTAssertNil(WebSearchConnector.freshness("whenever"))
    }

    func testQueriesAreEscapedSoPlusSignsSurvive() async throws {
        let mock = MockHTTPClient { _ in (200, body(self.results)) }
        _ = try await tool("web_search", in: connector(mock)).handler(ToolArguments(["query": "C++ tutorial & more"]))
        let url = try XCTUnwrap(mock.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("q=C%2B%2B%20tutorial%20%26%20more"), url)
    }

    func testVeryLongQueriesAreShortened() async throws {
        let mock = MockHTTPClient { _ in (200, body(self.results)) }
        _ = try await tool("web_search", in: connector(mock)).handler(ToolArguments(["query": String(repeating: "a", count: 1000)]))
        XCTAssertEqual(try XCTUnwrap(mock.requests.first).queryDictionary["q"]?.count, 300)
    }

    func testNoResultsAndMalformedItems() async throws {
        let empty = MockHTTPClient { _ in (200, body("{\"web\":{\"results\":[]}}")) }
        let none = try await tool("web_search", in: connector(empty)).handler(ToolArguments(["query": "zzz"]))
        XCTAssertEqual(none, "No web results for \"zzz\".")

        let missing = MockHTTPClient { _ in (200, body("{}")) }
        let noWeb = try await tool("web_search", in: connector(missing)).handler(ToolArguments(["query": "zzz"]))
        XCTAssertEqual(noWeb, "No web results for \"zzz\".")

        let partial = MockHTTPClient { _ in (200, body("{\"web\":{\"results\":[{\"url\":\"https://a.com\"},{\"title\":\"Only title\"}]}}")) }
        let output = try await tool("web_search", in: connector(partial)).handler(ToolArguments(["query": "q"]))
        XCTAssertEqual(output, "Web results for \"q\" (Brave Search):\n1. Only title | unknown source")
    }

    func testRejectedKeyAndRateLimitHaveClearMessages() async throws {
        for status in [401, 403] {
            let rejected = MockHTTPClient { _ in (status, body("{\"error\":{\"detail\":\"bad token\"}}")) }
            let search = try tool("web_search", in: connector(rejected))
            await assertFails(.authenticationFailed("Brave Search rejected the API key. Check BRAVE_API_KEY and rebuild (see docs/connectors.md).")) {
                _ = try await search.handler(ToolArguments(["query": "q"]))
            }
        }
        let limited = MockHTTPClient { _ in (429, Data()) }
        let search = try tool("web_search", in: connector(limited))
        await assertFails(.unexpectedResponse("Web search has hit its rate limit. Try again in a moment.")) {
            _ = try await search.handler(ToolArguments(["query": "q"]))
        }
    }

    func testBlankQueryIsRejectedWithoutANetworkCall() async throws {
        let mock = MockHTTPClient { _ in (200, body(self.results)) }
        let search = try tool("web_search", in: connector(mock))
        await assertFails(.invalidArgument("A search query is required.")) {
            _ = try await search.handler(ToolArguments(["query": "   "]))
        }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testOutputFitsTheToolBudgetEvenWithLongSnippets() async throws {
        let long = String(repeating: "word ", count: 400)
        let items = (1...5).map { "{\"title\":\"T\($0)\",\"url\":\"https://s\($0).com\",\"description\":\"\(long)\"}" }
        let mock = MockHTTPClient { _ in (200, body("{\"web\":{\"results\":[\(items.joined(separator: ","))]}}")) }
        let output = try await tool("web_search", in: connector(mock)).handler(ToolArguments(["query": "q", "limit": "5"]))
        XCTAssertLessThanOrEqual(TokenEstimator.estimate(output), 500, "five results must fit the 500-token tool budget")
        XCTAssertTrue(output.contains("5. T5"))
    }

    func testAPIKeyNeverAppearsInToolOutput() async throws {
        let mock = MockHTTPClient { _ in (200, body(self.results)) }
        let output = try await tool("web_search", in: connector(mock, key: "SECRET-KEY-123")).handler(ToolArguments(["query": "q"]))
        XCTAssertFalse(output.contains("SECRET-KEY-123"))
        XCTAssertFalse(try XCTUnwrap(mock.requests.first?.url?.absoluteString).contains("SECRET-KEY-123"), "the key goes in a header, not the URL")
    }
}

// MARK: - Together

final class LiveDataRegistryTests: XCTestCase {
    private func all() -> [any Connector] {
        [
            WeatherConnector(http: MockHTTPClient { _ in (404, Data()) }, imperial: false),
            StocksConnector(http: MockHTTPClient { _ in (404, Data()) }),
            WebSearchConnector(configuration: WebSearchConfiguration(apiKey: "k"), http: MockHTTPClient { _ in (404, Data()) }),
        ]
    }

    func testToolNamesAreUniqueAndNothingNeedsApproval() {
        let tools = all().flatMap { $0.tools() }
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count)
        XCTAssertEqual(Set(tools.map(\.name)), ["weather_forecast", "stock_quote", "web_search"])
        XCTAssertTrue(tools.allSatisfy { !$0.requiresApproval }, "live lookups are read-only")
    }

    func testAllThreeAreOffUntilSwitchedOnAndReportNetworkUse() async {
        let registry = ConnectorRegistry(connectors: all())
        let off = await registry.activeTools()
        XCTAssertTrue(off.isEmpty)

        let rows = await registry.snapshot()
        XCTAssertEqual(rows.map(\.id), ["weather", "stocks", "web_search"])
        XCTAssertTrue(rows.allSatisfy { $0.usesNetwork && !$0.hasAccount && !$0.isEnabled })

        for id in ["weather", "stocks", "web_search"] { await registry.setEnabled(id, true) }
        let active = await registry.activeTools()
        XCTAssertEqual(active.map(\.name), ["weather_forecast", "stock_quote", "web_search"])
        let activeRows = await registry.snapshot()
        XCTAssertTrue(activeRows.allSatisfy(\.isActive))
    }

    func testCalendarStaysOffTheNetworkAndGmailCountsAsNetwork() async {
        let registry = ConnectorRegistry(connectors: [
            CalendarConnector(provider: InMemoryCalendarProvider()),
            GmailConnector(configuration: nil, store: InMemoryTokenStore(), web: ScriptedWeb(outcome: .cancelled)),
        ])
        let rows = await registry.snapshot()
        XCTAssertEqual(rows.map(\.usesNetwork), [false, true])
    }

    func testDisconnectAllStyleSignOutLeavesKeylessConnectorsUntouched() async {
        // Keyless connectors hold no credentials, so they are not "accounts" and are not signed out.
        XCTAssertTrue(all().allSatisfy { !$0.hasAccount })
    }
}
