import SwiftUI
import MapKit
import ConnectorKit

/// MapKit map that prefers on-disk OpenTopoMap tiles from ready packs, with optional live tiles.
struct WildernessMapView: UIViewRepresentable {
    var fix: LocationFix?
    var waypoints: [WaypointInfo]
    var breadcrumbs: [BreadcrumbPoint]
    var packs: [OfflineMapPackInfo]
    var mapStore: OfflineMapFileStore?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.showsUserLocation = true
        map.isRotateEnabled = true
        map.isPitchEnabled = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncOverlays(on: map)
        context.coordinator.syncAnnotations(on: map)
        if let fix, context.coordinator.shouldRecenter {
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude),
                latitudinalMeters: 1_600,
                longitudinalMeters: 1_600
            )
            map.setRegion(region, animated: true)
            context.coordinator.shouldRecenter = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: WildernessMapView
        var shouldRecenter = true
        private var overlayPackIDs: Set<UUID> = []

        init(_ parent: WildernessMapView) { self.parent = parent }

        func syncOverlays(on map: MKMapView) {
            let ready = parent.packs.filter { $0.status == .ready }
            let ids = Set(ready.map(\.id))
            if ids == overlayPackIDs { return }
            map.removeOverlays(map.overlays)
            overlayPackIDs = ids
            for pack in ready {
                let overlay = OfflineMapTileOverlay(pack: pack, store: parent.mapStore)
                overlay.canReplaceMapContent = false
                map.addOverlay(overlay, level: .aboveRoads)
            }
        }

        func syncAnnotations(on map: MKMapView) {
            map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
            for waypoint in parent.waypoints {
                let pin = MKPointAnnotation()
                pin.coordinate = CLLocationCoordinate2D(latitude: waypoint.latitude, longitude: waypoint.longitude)
                pin.title = waypoint.name
                pin.subtitle = waypoint.notes.isEmpty ? nil : waypoint.notes
                map.addAnnotation(pin)
            }
            if parent.breadcrumbs.count >= 2 {
                let coords = parent.breadcrumbs.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let polyline = MKPolyline(coordinates: coords, count: coords.count)
                map.addOverlay(polyline, level: .aboveRoads)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.85)
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

/// Loads `{z}/{x}/{y}` from a downloaded pack; falls back to OpenTopoMap when online if missing.
final class OfflineMapTileOverlay: MKTileOverlay, @unchecked Sendable {
    private let pack: OfflineMapPackInfo
    private let store: OfflineMapFileStore?

    init(pack: OfflineMapPackInfo, store: OfflineMapFileStore?) {
        self.pack = pack
        self.store = store
        super.init(urlTemplate: OfflineMapDownloader.defaultTileURLTemplate)
        minimumZ = pack.minZoom
        maximumZ = pack.maxZoom
    }

    override func loadTile(at path: MKTileOverlayPath) async throws -> Data {
        if let store, let data = await store.loadTile(packID: pack.id, z: path.z, x: path.x, y: path.y) {
            return data
        }
        // Missing tile inside the pack zoom range: try the network template when online.
        // Outside that range (or fully offline with no file): transparent tile.
        if path.z >= pack.minZoom && path.z <= pack.maxZoom {
            return try await super.loadTile(at: path)
        }
        return Data()
    }
}
