# Trail: GPS, waypoints, offline maps, motion, and AR

Applebot’s **Trail** tab helps when you are outdoors with weak or no cell signal: GPS coordinates, compass bearings to saved waypoints, a breadcrumb trail, cached weather for “here”, **downloaded topographic map packs**, an optional **Motion sedentary check**, and an **AR trail overlay** (with LiDAR mesh on Pro models only).

## What you get

| Feature | Offline? | Notes |
|---|---|---|
| Current GPS (lat/lon, accuracy, altitude, course) | Yes | Needs a clear sky; no cell required |
| Waypoints (Car, Camp, Trailhead…) | Yes | Stored on this iPhone |
| Bearing + distance to a waypoint | Yes | True north |
| Breadcrumb trail | Yes | Optional continuous recording |
| Weather for “here” | Needs signal once | Then uses the last cached forecast offline |
| Offline map packs | Download once | Pan-to-select area (Google Maps–style), OpenTopoMap tiles on disk; MapKit overlay |
| Motion / sedentary | Yes | Pedometer + activity; soft check only. Connect **Motion** first |
| AR trail overlay | Yes | Camera HUD + bearings. Works without LiDAR |
| LiDAR depth mesh | Yes | **Pro / Pro Max only.** Disabled with a warning on iPhone Air and other non-LiDAR phones |

## Setup

1. Open **Trail** (or **You → Connectors → Location**) and tap **Connect Location**. Allow **While Using** when iOS asks.
2. Turn on **Use in chats** for **Location** (and **Weather** if you want forecasts).
3. Optional: **Connect Motion** on the Trail tab (or Connectors) and allow **Motion & Fitness** for sedentary checks.
4. While you still have signal, open Trail → **Download** (or ⋯ → **Download offline map**):
   - Pan and pinch the map under the dashed frame (same idea as Google Maps offline areas).
   - Name the area, pick **Overview / Standard / More detail**, check the size estimate, then **Download**.
   - Manage areas under **Offline maps**: rename, update, or delete.
5. Save a **Car** / **Camp** waypoint at the trailhead before you hike.
6. Optional: **Open AR overlay** (⋯ or the AR card). Allow Camera when asked. On non-LiDAR phones the depth-mesh toggle stays off with a warning.

## Sensor warnings (Air vs Pro)

Applebot probes capabilities at runtime:

| Capability | Typical iPhone Air | Typical iPhone 17 Pro |
|---|---|---|
| GPS / compass map | Yes | Yes |
| Motion sedentary (steps / activity) | Yes | Yes |
| AR compass overlay | Yes (if ARKit world tracking) | Yes |
| LiDAR depth mesh | **No** — toggle disabled + warning | Yes |

Only the missing slice is disabled. GPS, waypoints, offline maps, and the compass AR HUD keep working without LiDAR.

## Chat tools

When Location is connected and enabled, the model can call:

| Tool | Purpose |
|---|---|
| `location_current` | GPS fix; optional breadcrumb |
| `location_list_waypoints` | Saved places |
| `location_add_waypoint` | Save a place (**approval** required) |
| `location_bearing` | Distance + bearing to a waypoint or coordinates |
| `location_breadcrumbs` | Trail summary |
| `location_list_map_packs` | Downloaded offline maps |

When Motion is connected:

| Tool | Purpose |
|---|---|
| `motion_sedentary` | Activity + recent steps; soft sedentary likely flag |
| `motion_capabilities` | Which motion sensors are available / disabled |

Weather accepts `location: "here"` (or GPS lat/lon). On network failure it returns the **cached** forecast with an age label.

## Privacy

- GPS, waypoints, motion summaries, and AR camera frames never leave the device.
- Offline map **download** talks to OpenTopoMap once; after that tiles are read from disk.
- Weather still sends coordinates or a city name to Open-Meteo when online.
- Same connector toggles as everything else: off means unused.

## Limits and safety

- Not a certified wilderness navigation instrument. Carry a paper map and a real compass for serious trips.
- Bearings are **true north**, not magnetic.
- Sedentary check is informational only — not medical advice.
- Pack size is capped (~2,500 tiles) so downloads stay phone-friendly. Shrink the area or max zoom if validation fails.
- Map attribution: © OpenStreetMap contributors, SRTM | © OpenTopoMap (CC-BY-SA).

## Developer map

| Piece | Location |
|---|---|
| Geo math + tile grid | `ConnectorKit/GeoMath.swift` |
| Models | `ConnectorKit/LocationModels.swift` |
| Sensor capability | `ConnectorKit/SensorCapability.swift` |
| Provider / stores | `ConnectorKit/LocationProvider.swift`, `MotionProvider.swift` |
| Chat connectors | `ConnectorKit/LocationConnector.swift`, `MotionConnector.swift` |
| Core Motion | `ConnectorKit/CoreMotionStoreProvider.swift` (`#if canImport(CoreMotion)`) |
| Pack download | `ConnectorKit/OfflineMapDownloader.swift` |
| Weather here + cache | `ConnectorKit/WeatherConnector.swift` |
| Core Location | `App/Services/CoreLocationProvider.swift` |
| AR capability probe | `App/Services/TrailARCapabilityProbe.swift` |
| File stores | `App/Services/FileTrailStore.swift`, `OfflineMapFileStore.swift` |
| Trail UI | `App/Views/WildernessView.swift`, `WildernessMapView.swift`, `OfflineMapDownloadSheet.swift`, `ARTrailOverlayView.swift` |
| Tests | `tests/ConnectorKitTests/LocationConnectorTests.swift`, `MotionConnectorTests.swift` |

## Troubleshooting

| Symptom | Fix |
|---|---|
| “Location access was denied” | Settings app → Applebot → Location → While Using |
| No GPS fix | Move outdoors; wait for a lock; refresh GPS on Trail |
| Map is blank offline | Download a pack while online; confirm status is `ready` |
| Weather invents numbers | Enable Weather + Location; ask “weather here” |
| Pack too large | Use a smaller region or lower max zoom |
| “LiDAR depth mesh… disabled” | Expected on iPhone Air / non-Pro. Use compass AR overlay; mesh needs a Pro with LiDAR |
| Motion / sedentary unavailable | Connect Motion; allow Motion & Fitness. Simulators may lack pedometer/activity |
| AR overlay unavailable | Device lacks ARKit world tracking; GPS map still works |
