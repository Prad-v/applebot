import Foundation

/// Pure geo helpers for GPS tools and offline map tile math. No Apple frameworks.
public enum GeoMath {
    public static let earthRadiusMeters = 6_371_000.0

    /// Great-circle distance in meters (haversine).
    public static func distanceMeters(
        fromLat: Double, fromLon: Double,
        toLat: Double, toLon: Double
    ) -> Double {
        let φ1 = fromLat * .pi / 180
        let φ2 = toLat * .pi / 180
        let Δφ = (toLat - fromLat) * .pi / 180
        let Δλ = (toLon - fromLon) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2)
            + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(a)))
    }

    /// Initial bearing in degrees [0, 360), clockwise from true north.
    public static func bearingDegrees(
        fromLat: Double, fromLon: Double,
        toLat: Double, toLon: Double
    ) -> Double {
        let φ1 = fromLat * .pi / 180
        let φ2 = toLat * .pi / 180
        let Δλ = (toLon - fromLon) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let θ = atan2(y, x) * 180 / .pi
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Compass-style label for a bearing (N, NNE, …).
    public static func cardinal(forBearingDegrees bearing: Double) -> String {
        let labels = [
            "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
            "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
        ]
        let index = Int((bearing / 22.5).rounded()) % 16
        return labels[(index + 16) % 16]
    }

    public static func formatDistanceMeters(_ meters: Double, imperial: Bool) -> String {
        if imperial {
            let feet = meters * 3.28084
            if feet < 528 {
                return "\(LiveData.number(feet)) ft"
            }
            let miles = meters / 1609.344
            return "\(LiveData.number(miles, decimals: miles < 10 ? 2 : 1)) mi"
        }
        if meters < 1000 {
            return "\(LiveData.number(meters)) m"
        }
        let km = meters / 1000
        return "\(LiveData.number(km, decimals: km < 10 ? 2 : 1)) km"
    }

    // MARK: Web-mercator tiles

    /// Slippy-map tile X for longitude at zoom `z`.
    public static func tileX(longitude: Double, zoom: Int) -> Int {
        let n = Double(1 << zoom)
        let x = Int(floor((longitude + 180) / 360 * n))
        return min(max(x, 0), Int(n) - 1)
    }

    /// Slippy-map tile Y for latitude at zoom `z`.
    public static func tileY(latitude: Double, zoom: Int) -> Int {
        let lat = min(max(latitude, -85.05112878), 85.05112878)
        let φ = lat * .pi / 180
        let n = Double(1 << zoom)
        let y = Int(floor((1 - log(tan(φ) + 1 / cos(φ)) / .pi) / 2 * n))
        return min(max(y, 0), Int(n) - 1)
    }

    /// Northwest corner latitude/longitude of tile (x, y) at zoom `z`.
    public static func tileNorthwest(x: Int, y: Int, zoom: Int) -> (lat: Double, lon: Double) {
        let n = Double(1 << zoom)
        let lon = Double(x) / n * 360 - 180
        let latRad = atan(sinh(.pi * (1 - 2 * Double(y) / n)))
        return (latRad * 180 / .pi, lon)
    }

    /// All tile coordinates covering a bounding box at one zoom (inclusive).
    public static func tiles(
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double, zoom: Int
    ) -> [(x: Int, y: Int)] {
        let west = min(minLon, maxLon)
        let east = max(minLon, maxLon)
        let south = min(minLat, maxLat)
        let north = max(minLat, maxLat)
        let x0 = tileX(longitude: west, zoom: zoom)
        let x1 = tileX(longitude: east, zoom: zoom)
        let y0 = tileY(latitude: north, zoom: zoom)
        let y1 = tileY(latitude: south, zoom: zoom)
        var result: [(Int, Int)] = []
        for x in x0...x1 {
            for y in y0...y1 {
                result.append((x, y))
            }
        }
        return result
    }

    /// Count of tiles across `minZoom...maxZoom` for a bounding box.
    public static func tileCount(
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
        minZoom: Int, maxZoom: Int
    ) -> Int {
        guard minZoom <= maxZoom else { return 0 }
        var total = 0
        for z in minZoom...maxZoom {
            total += tiles(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon, zoom: z).count
        }
        return total
    }
}
