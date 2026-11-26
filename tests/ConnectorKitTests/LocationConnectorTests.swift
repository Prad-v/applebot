import XCTest
import LLMKit
@testable import ConnectorKit

private func tool(_ name: String, in connector: some Connector) throws -> ToolSpec {
    try XCTUnwrap(connector.tools().first { $0.name == name })
}

final class GeoMathTests: XCTestCase {
    func testDistanceAndBearingBetweenKnownPoints() {
        // Roughly SF → Oakland (~13–16 km east-northeast).
        let meters = GeoMath.distanceMeters(
            fromLat: 37.7749, fromLon: -122.4194,
            toLat: 37.8044, toLon: -122.2712
        )
        XCTAssertEqual(meters, 14_000, accuracy: 3_000)
        let bearing = GeoMath.bearingDegrees(
            fromLat: 37.7749, fromLon: -122.4194,
            toLat: 37.8044, toLon: -122.2712
        )
        XCTAssertEqual(bearing, 75, accuracy: 20)
        XCTAssertEqual(GeoMath.cardinal(forBearingDegrees: 0), "N")
        XCTAssertEqual(GeoMath.cardinal(forBearingDegrees: 90), "E")
    }

    func testTileMathCoversABoundingBox() {
        let tiles = GeoMath.tiles(
            minLat: 37.7, minLon: -122.5, maxLat: 37.8, maxLon: -122.4, zoom: 10
        )
        XCTAssertFalse(tiles.isEmpty)
        let count = GeoMath.tileCount(
            minLat: 37.7, minLon: -122.5, maxLat: 37.8, maxLon: -122.4,
            minZoom: 10, maxZoom: 11
        )
        XCTAssertGreaterThan(count, tiles.count)
    }

    func testValidateRejectsHugePacks() {
        XCTAssertThrowsError(
            try OfflineMapDownloader.validate(
                minLat: 30, minLon: -130, maxLat: 50, maxLon: -100,
                minZoom: 8, maxZoom: 14
            )
        )
    }
}

final class LocationConnectorTests: XCTestCase {
    func testToolsAndCurrentFix() async throws {
        let provider = InMemoryLocationProvider(
            permission: .authorized,
            fix: LocationFix(latitude: 46.8523, longitude: -121.7603, altitudeMeters: 4_392, horizontalAccuracyMeters: 5)
        )
        let trail = InMemoryTrailStore()
        let connector = LocationConnector(provider: provider, trail: trail, imperial: false)
        XCTAssertEqual(connector.id, "location")
        XCTAssertFalse(connector.usesNetwork)
        let status = await connector.status()
        XCTAssertEqual(status, .connected(account: nil))

        let output = try await tool("location_current", in: connector).handler(ToolArguments([:]))
        XCTAssertTrue(output.contains("46.85230"))
        XCTAssertTrue(output.contains("121.76030"))
    }

    func testWaypointBearingAndList() async throws {
        let provider = InMemoryLocationProvider(
            fix: LocationFix(latitude: 37.7749, longitude: -122.4194)
        )
        let trail = InMemoryTrailStore(waypoints: [
            WaypointInfo(name: "Car", latitude: 37.8044, longitude: -122.2712),
        ])
        let connector = LocationConnector(provider: provider, trail: trail, imperial: true)
        let bearing = try await tool("location_bearing", in: connector)
            .handler(ToolArguments(["waypoint": "Car"]))
        XCTAssertTrue(bearing.lowercased().contains("car"))
        XCTAssertTrue(bearing.contains("Bearing"))

        let list = try await tool("location_list_waypoints", in: connector).handler(ToolArguments([:]))
        XCTAssertTrue(list.contains("Car"))
    }

    func testAddWaypointRequiresApprovalFlag() throws {
        let connector = LocationConnector(provider: InMemoryLocationProvider())
        let add = try tool("location_add_waypoint", in: connector)
        XCTAssertTrue(add.requiresApproval)
    }

    func testBreadcrumbsSummary() async throws {
        let trail = InMemoryTrailStore(breadcrumbs: [
            BreadcrumbPoint(latitude: 37.77, longitude: -122.42, timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
            BreadcrumbPoint(latitude: 37.78, longitude: -122.41, timestamp: Date(timeIntervalSince1970: 1_700_000_600)),
        ])
        let connector = LocationConnector(provider: InMemoryLocationProvider(), trail: trail)
        let summary = try await tool("location_breadcrumbs", in: connector).handler(ToolArguments([:]))
        XCTAssertTrue(summary.contains("2 points"))
    }

    func testListMapPacks() async throws {
        let maps = InMemoryOfflineMapStore(packs: [
            OfflineMapPackInfo(
                name: "Rainier",
                minLatitude: 46.8, minLongitude: -121.9,
                maxLatitude: 46.9, maxLongitude: -121.7,
                tileCount: 120, byteSize: 2_000_000, status: .ready
            ),
        ])
        let connector = LocationConnector(provider: InMemoryLocationProvider(), maps: maps)
        let list = try await tool("location_list_map_packs", in: connector).handler(ToolArguments([:]))
        XCTAssertTrue(list.contains("Rainier"))
        XCTAssertTrue(list.contains("ready"))
    }
}

final class OfflineMapDownloaderTests: XCTestCase {
    func testDownloadWritesTiles() async throws {
        let store = InMemoryOfflineMapStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47]) // minimal stand-in
        let http = MockHTTPClient { _ in (200, png) }
        let downloader = OfflineMapDownloader(store: store, http: http, tileURLTemplate: "https://example.test/{z}/{x}/{y}.png")
        var pack = OfflineMapPackInfo(
            name: "Tiny",
            minLatitude: 37.77, minLongitude: -122.42,
            maxLatitude: 37.78, maxLongitude: -122.41,
            minZoom: 12, maxZoom: 12
        )
        let expected = try OfflineMapDownloader.validate(
            minLat: pack.minLatitude, minLon: pack.minLongitude,
            maxLat: pack.maxLatitude, maxLon: pack.maxLongitude,
            minZoom: pack.minZoom, maxZoom: pack.maxZoom
        )
        XCTAssertGreaterThan(expected, 0)
        pack = try await downloader.download(pack: pack)
        XCTAssertEqual(pack.status, .ready)
        XCTAssertEqual(pack.tileCount, expected)
        let packs = await store.packs()
        XCTAssertEqual(packs.count, 1)
    }

    func testTileURLTemplate() throws {
        let url = try OfflineMapDownloader.tileURL(
            template: "https://tile.opentopomap.org/{z}/{x}/{y}.png",
            z: 10, x: 163, y: 395
        )
        XCTAssertEqual(url.absoluteString, "https://tile.opentopomap.org/10/163/395.png")
    }

    func testEstimateReportsValidSizeForSmallRegion() {
        let estimate = OfflineMapDownloader.estimate(
            minLat: 37.77, minLon: -122.42,
            maxLat: 37.78, maxLon: -122.41,
            minZoom: OfflineMapDetail.standard.minZoom,
            maxZoom: OfflineMapDetail.standard.maxZoom
        )
        XCTAssertTrue(estimate.isValid)
        XCTAssertGreaterThan(estimate.tileCount, 0)
        XCTAssertTrue(estimate.sizeLine.contains("about") || estimate.sizeLine.contains("MB") || estimate.sizeLine.contains("tiles"))
    }

    func testEstimateInvalidWhenTooLarge() {
        let estimate = OfflineMapDownloader.estimate(
            minLat: 30, minLon: -130, maxLat: 50, maxLon: -100,
            minZoom: 8, maxZoom: 14
        )
        XCTAssertFalse(estimate.isValid)
        XCTAssertNotNil(estimate.message)
    }

    func testPackFromDetailPresets() {
        let pack = OfflineMapDownloader.pack(
            name: "Camp",
            minLat: 46.8, minLon: -121.9,
            maxLat: 46.9, maxLon: -121.7,
            detail: .overview
        )
        XCTAssertEqual(pack.name, "Camp")
        XCTAssertEqual(pack.minZoom, OfflineMapDetail.overview.minZoom)
        XCTAssertEqual(pack.maxZoom, OfflineMapDetail.overview.maxZoom)
    }
}

final class WeatherHereAndCacheTests: XCTestCase {
    func testForecastHereUsesGPS() async throws {
        let forecastJSON = """
        {"timezone":"UTC",
         "current":{"time":"2026-11-21T09:30","temperature_2m":2.0,"apparent_temperature":0.0,"relative_humidity_2m":80,
                    "precipitation":0.0,"weather_code":0,"wind_speed_10m":5.0},
         "daily":{"time":["2026-11-21"],"weather_code":[0],
                  "temperature_2m_max":[4.0],"temperature_2m_min":[-1.0],
                  "precipitation_probability_max":[10]}}
        """
        let provider = InMemoryLocationProvider(
            fix: LocationFix(latitude: 46.85, longitude: -121.76)
        )
        let body = Data(forecastJSON.utf8)
        let http = MockHTTPClient { request in
            XCTAssertEqual(request.url?.host, "api.open-meteo.com")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let lat = items.first { $0.name == "latitude" }?.value
            XCTAssertEqual(lat, "46.85")
            return (200, body)
        }
        let cache = InMemoryWeatherCacheStore()
        let connector = WeatherConnector(http: http, imperial: false, locationProvider: provider, cache: cache)
        let output = try await tool("weather_forecast", in: connector)
            .handler(ToolArguments(["location": "here"]))
        XCTAssertTrue(output.contains("Current location") || output.contains("2"))
        let cached = await cache.load()
        XCTAssertNotNil(cached)
    }

    func testOfflineFallsBackToCache() async throws {
        let cache = InMemoryWeatherCacheStore(
            cached: CachedWeather(
                placeTitle: "Camp",
                latitude: 1, longitude: 2,
                renderedText: "Weather for Camp.\nNow: 3°C",
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let http = MockHTTPClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let connector = WeatherConnector(
            http: http,
            locationProvider: InMemoryLocationProvider(),
            cache: cache,
            clock: { Date(timeIntervalSince1970: 1_700_003_600) }
        )
        let output = try await tool("weather_forecast", in: connector)
            .handler(ToolArguments(["location": "here"]))
        XCTAssertTrue(output.contains("cached weather"))
        XCTAssertTrue(output.contains("Weather for Camp"))
    }
}
