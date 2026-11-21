import Foundation
import LLMKit

/// Current weather and a short forecast for any place, from Open-Meteo (no account, no API key).
///
/// Only the place name the user asked about leaves the device.
public struct WeatherConnector: Connector {
    public let id = "weather"
    public let displayName = "Weather"
    public let summary = "Current weather and a forecast for any city."
    public let symbolName = "cloud.sun"
    public let dataNote = "Sends only the place you ask about to Open-Meteo (open-meteo.com). No account, and nothing else leaves this iPhone."
    public let hasAccount = false
    public var usesNetwork: Bool { true }

    public static let maxDays = 7
    public static let defaultDays = 3

    static let geocodingURL = "https://geocoding-api.open-meteo.com/v1/search"
    static let forecastURL = "https://api.open-meteo.com/v1/forecast"
    static let service = "Open-Meteo"

    private let http: HTTPClient
    private let imperial: Bool

    /// `imperial` is the default unit system when the question does not say; it follows the device region.
    public init(
        http: HTTPClient = URLSessionHTTPClient(),
        imperial: Bool = Locale.current.measurementSystem == .us
    ) {
        self.http = http
        self.imperial = imperial
    }

    public func status() async -> ConnectorStatus { .connected(account: nil) }
    public func connect() async throws {}
    public func disconnect() async {}

    public func tools() -> [ToolSpec] { [forecastTool] }

    // MARK: Tool

    private var forecastTool: ToolSpec {
        let http = self.http, imperial = self.imperial
        return ToolSpec(
            name: "weather_forecast",
            description: "Get the current weather and a daily forecast for a place. Use for any question about weather, temperature, rain, wind or whether to bring an umbrella or jacket.",
            parameters: [
                ToolParameter("location", "City name, optionally with country or state, for example 'Paris, France' or 'Austin, Texas'."),
                ToolParameter("days", "Days of forecast, 1 to \(Self.maxDays). Defaults to \(Self.defaultDays).", kind: .integer, required: false),
                ToolParameter("units", "'metric' (Celsius) or 'imperial' (Fahrenheit). Defaults to the device region.", required: false),
            ],
            label: "Checking the weather",
            handler: { arguments in
                guard let location = arguments.string("location") else {
                    throw ConnectorError.invalidArgument("A location is required, for example 'Paris, France'.")
                }
                let days = min(max(arguments.integer("days") ?? Self.defaultDays, 1), Self.maxDays)
                let useImperial = Self.wantsImperial(arguments.string("units")) ?? imperial
                let place = try await Self.geocode(location, http: http)
                let forecast = try await Self.forecast(for: place, days: days, imperial: useImperial, http: http)
                return Self.render(place: place, forecast: forecast, imperial: useImperial)
            }
        )
    }

    // MARK: Geocoding

    struct Place: Decodable, Equatable {
        var name: String
        var latitude: Double
        var longitude: Double
        var country: String?
        var countryCode: String?
        var admin1: String?

        enum CodingKeys: String, CodingKey {
            case name, latitude, longitude, country, admin1
            case countryCode = "country_code"
        }

        var title: String {
            var parts = [name]
            if let admin1, !admin1.isEmpty, admin1 != name { parts.append(admin1) }
            if let country, !country.isEmpty { parts.append(country) }
            return parts.joined(separator: ", ")
        }
    }

    private struct GeocodeResponse: Decodable { var results: [Place]? }

    static func geocode(_ location: String, http: HTTPClient) async throws -> Place {
        // Open-Meteo matches on the name only, so "Paris, France" is split into a name and a hint.
        let pieces = location.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = pieces.first, name.count >= 2 else {
            throw ConnectorError.invalidArgument("A location is required, for example 'Paris, France'.")
        }
        let hint = pieces.count > 1 ? pieces[1] : nil
        let url = try LiveData.url(geocodingURL, ["name": name, "count": "10", "language": "en", "format": "json"])
        let data = try await LiveData.fetch(http, url, service: service)
        let places = try LiveData.decode(GeocodeResponse.self, from: data, service: service).results ?? []
        guard let place = choose(places, hint: hint) else {
            throw ConnectorError.invalidArgument(
                "Couldn't find a place called \"\(location)\". Try the city with its country, like \"Paris, France\"."
            )
        }
        return place
    }

    static func choose(_ places: [Place], hint: String?) -> Place? {
        guard let hint = hint?.lowercased(), !hint.isEmpty else { return places.first }
        let match = places.first { place in
            if place.countryCode?.lowercased() == hint { return true }
            return [place.country, place.admin1].compactMap { $0?.lowercased() }.contains { value in
                !value.isEmpty && (value == hint || hint.contains(value))
            }
        }
        return match ?? places.first
    }

    // MARK: Forecast

    struct Forecast: Decodable {
        struct Current: Decodable {
            var time: String
            var temperature: Double?
            var feelsLike: Double?
            var humidity: Double?
            var precipitation: Double?
            var code: Int?
            var wind: Double?

            enum CodingKeys: String, CodingKey {
                case time
                case temperature = "temperature_2m"
                case feelsLike = "apparent_temperature"
                case humidity = "relative_humidity_2m"
                case precipitation
                case code = "weather_code"
                case wind = "wind_speed_10m"
            }
        }

        struct Daily: Decodable {
            var time: [String]
            var code: [Int?]
            var high: [Double?]
            var low: [Double?]
            var rainChance: [Double?]

            enum CodingKeys: String, CodingKey {
                case time
                case code = "weather_code"
                case high = "temperature_2m_max"
                case low = "temperature_2m_min"
                case rainChance = "precipitation_probability_max"
            }
        }

        var current: Current?
        var daily: Daily?
    }

    static func forecast(for place: Place, days: Int, imperial: Bool, http: HTTPClient) async throws -> Forecast {
        let url = try LiveData.url(forecastURL, [
            "latitude": String(place.latitude),
            "longitude": String(place.longitude),
            "current": "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m",
            "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
            "forecast_days": String(days),
            "timezone": "auto",
            "temperature_unit": imperial ? "fahrenheit" : "celsius",
            "wind_speed_unit": imperial ? "mph" : "kmh",
            "precipitation_unit": imperial ? "inch" : "mm",
        ])
        let data = try await LiveData.fetch(http, url, service: service)
        return try LiveData.decode(Forecast.self, from: data, service: service)
    }

    // MARK: Output

    static func render(place: Place, forecast: Forecast, imperial: Bool) -> String {
        let degrees = imperial ? "°F" : "°C"
        let speed = imperial ? "mph" : "km/h"
        let rain = imperial ? "in" : "mm"
        var lines: [String] = []

        if let current = forecast.current {
            lines.append("Weather for \(place.title). Local time \(current.time.replacingOccurrences(of: "T", with: " ")).")
            var now = ["Now:"]
            if let temperature = current.temperature {
                var text = "\(LiveData.number(temperature))\(degrees)"
                if let feels = current.feelsLike { text += " (feels like \(LiveData.number(feels))\(degrees))" }
                now.append(text + ",")
            }
            if let code = current.code { now.append(describe(code) + ",") }
            if let humidity = current.humidity { now.append("humidity \(LiveData.number(humidity))%,") }
            if let wind = current.wind { now.append("wind \(LiveData.number(wind)) \(speed),") }
            if let precipitation = current.precipitation {
                now.append("precipitation \(LiveData.number(precipitation, decimals: 1)) \(rain).")
            }
            lines.append(now.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",")))
        } else {
            lines.append("Weather for \(place.title).")
        }

        if let daily = forecast.daily, !daily.time.isEmpty {
            lines.append("Forecast:")
            for index in daily.time.indices {
                var line = "- \(dayLabel(daily.time[index])):"
                if let high = value(daily.high, index), let low = value(daily.low, index) {
                    line += " \(LiveData.number(low)) to \(LiveData.number(high))\(degrees)"
                }
                if let code = daily.code.indices.contains(index) ? daily.code[index] : nil {
                    line += ", \(describe(code))"
                }
                if let chance = value(daily.rainChance, index) {
                    line += ", \(LiveData.number(chance))% chance of precipitation"
                }
                lines.append(line)
            }
        }
        lines.append("Source: Open-Meteo.")
        return lines.joined(separator: "\n")
    }

    private static func value(_ values: [Double?], _ index: Int) -> Double? {
        values.indices.contains(index) ? values[index] : nil
    }

    /// "2026-11-21" as `Sat 2026-11-21`. The date is already local to the place, so it is read as UTC.
    static func dayLabel(_ isoDay: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: isoDay) else { return isoDay }
        return DateInput.format(date, calendar: calendar, includeTime: false)
    }

    /// `true` for imperial, `false` for metric, `nil` when unspecified or unrecognised.
    static func wantsImperial(_ text: String?) -> Bool? {
        switch text?.lowercased() {
        case "imperial", "fahrenheit", "f", "us", "mph": return true
        case "metric", "celsius", "c", "si", "kmh": return false
        default: return nil
        }
    }

    /// WMO weather interpretation codes, as used by Open-Meteo.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71: return "light snow"
        case 73: return "snow"
        case 75: return "heavy snow"
        case 77: return "snow grains"
        case 80: return "light rain showers"
        case 81: return "rain showers"
        case 82: return "violent rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return "unsettled"
        }
    }
}
