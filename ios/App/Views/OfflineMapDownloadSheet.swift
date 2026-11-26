import SwiftUI
import MapKit
import ConnectorKit

/// Google Maps–style offline area picker: pan/zoom under a fixed frame, see size, then download.
struct OfflineMapDownloadSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Offline area"
    @State private var detail: OfflineMapDetail = .standard
    @State private var bounds: MapSelectionBounds?
    @State private var estimate = OfflineMapEstimate(tileCount: 0, estimatedBytes: 0, isValid: false)
    @State private var didCenterOnUser = false

    private var trail: WildernessDashboardController { environment.wilderness }

    private var center: CLLocationCoordinate2D {
        if let fix = trail.fix {
            return CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        }
        return CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                OfflineAreaSelectMap(
                    initialCenter: center,
                    onBoundsChange: { next in
                        bounds = next
                        refreshEstimate()
                    }
                )
                .ignoresSafeArea()

                selectionChrome
                    .allowsHitTesting(false)

                bottomPanel
            }
            .navigationTitle("Download offline map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NotificationCenter.default.post(name: OfflineAreaSelectMap.recenterNotification, object: center)
                    } label: {
                        Image(systemName: "location.fill")
                    }
                    .accessibilityLabel("Center on my location")
                }
            }
            .onChange(of: detail) { _, _ in refreshEstimate() }
            .onChange(of: trail.downloadProgress) { _, progress in
                // Dismiss after a successful download finishes.
                if progress == nil, trail.statusMessage?.contains("ready") == true {
                    dismiss()
                }
            }
            .task {
                if trail.fix == nil {
                    await trail.refreshFix()
                }
            }
            .interactiveDismissDisabled(trail.downloadProgress != nil)
        }
    }

    /// Dim outside a fixed rectangle (map pans underneath — same idea as Google Maps).
    private var selectionChrome: some View {
        GeometryReader { geo in
            let rect = Self.selectionRect(in: geo.size)
            ZStack {
                Color.black.opacity(0.38)
                    .reverseMask {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Text("Move the map to choose an area")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .position(x: geo.size.width / 2, y: rect.minY - 22)
            }
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Area name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("offline-map-name")

            Picker("Detail", selection: $detail) {
                ForEach(OfflineMapDetail.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("offline-map-detail")

            VStack(alignment: .leading, spacing: 4) {
                Text(estimate.sizeLine)
                    .font(.headline)
                if let message = estimate.message, !estimate.isValid {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    Text("Download on Wi‑Fi when you can. Uses OpenTopoMap; works offline after.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = trail.downloadProgress {
                ProgressView(value: progress) {
                    Text("Downloading… \(Int(progress * 100))%")
                        .font(.footnote)
                }
                Button("Cancel download", role: .destructive) {
                    trail.cancelDownload()
                }
            } else {
                Button {
                    Task { await startDownload() }
                } label: {
                    Text("Download")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!estimate.isValid || bounds == nil)
                .accessibilityIdentifier("offline-map-download")
            }
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private func refreshEstimate() {
        guard let bounds else { return }
        estimate = OfflineMapDownloader.estimate(
            minLat: bounds.minLatitude, minLon: bounds.minLongitude,
            maxLat: bounds.maxLatitude, maxLon: bounds.maxLongitude,
            minZoom: detail.minZoom, maxZoom: detail.maxZoom
        )
    }

    private func startDownload() async {
        guard let bounds else { return }
        let pack = OfflineMapDownloader.pack(
            name: name,
            minLat: bounds.minLatitude, minLon: bounds.minLongitude,
            maxLat: bounds.maxLatitude, maxLon: bounds.maxLongitude,
            detail: detail
        )
        await trail.downloadPack(pack)
    }

    /// Centered selection rectangle (~76% × 42% of the map), Google Maps–like.
    static func selectionRect(in size: CGSize) -> CGRect {
        let width = size.width * 0.78
        let height = size.height * 0.36
        return CGRect(
            x: (size.width - width) / 2,
            y: size.height * 0.22,
            width: width,
            height: height
        )
    }
}

struct MapSelectionBounds: Equatable {
    var minLatitude: Double
    var minLongitude: Double
    var maxLatitude: Double
    var maxLongitude: Double
}

/// MapKit map that reports the lat/lon of a fixed on-screen selection rectangle as you pan/zoom.
struct OfflineAreaSelectMap: UIViewRepresentable {
    var initialCenter: CLLocationCoordinate2D
    var onBoundsChange: (MapSelectionBounds) -> Void

    static let recenterNotification = Notification.Name("applebot.offlineMap.recenter")

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        let region = MKCoordinateRegion(center: initialCenter, latitudinalMeters: 18_000, longitudinalMeters: 18_000)
        map.setRegion(region, animated: false)
        context.coordinator.onBoundsChange = onBoundsChange
        context.coordinator.observeRecenter(map)
        DispatchQueue.main.async {
            context.coordinator.publishBounds(from: map)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onBoundsChange = onBoundsChange
    }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var onBoundsChange: ((MapSelectionBounds) -> Void)?
        private var recenterObserver: (any NSObjectProtocol)?

        func observeRecenter(_ map: MKMapView) {
            tearDown()
            recenterObserver = NotificationCenter.default.addObserver(
                forName: OfflineAreaSelectMap.recenterNotification,
                object: nil,
                queue: .main
            ) { [weak map] note in
                guard let map, let coordinate = note.object as? CLLocationCoordinate2D else { return }
                let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 18_000, longitudinalMeters: 18_000)
                Task { @MainActor in
                    map.setRegion(region, animated: true)
                }
            }
        }

        func tearDown() {
            if let recenterObserver {
                NotificationCenter.default.removeObserver(recenterObserver)
                self.recenterObserver = nil
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            publishBounds(from: mapView)
        }

        func publishBounds(from map: MKMapView) {
            let size = map.bounds.size
            guard size.width > 1, size.height > 1 else { return }
            let rect = OfflineMapDownloadSheet.selectionRect(in: size)
            let topLeft = map.convert(CGPoint(x: rect.minX, y: rect.minY), toCoordinateFrom: map)
            let bottomRight = map.convert(CGPoint(x: rect.maxX, y: rect.maxY), toCoordinateFrom: map)
            let bounds = MapSelectionBounds(
                minLatitude: min(topLeft.latitude, bottomRight.latitude),
                minLongitude: min(topLeft.longitude, bottomRight.longitude),
                maxLatitude: max(topLeft.latitude, bottomRight.latitude),
                maxLongitude: max(topLeft.longitude, bottomRight.longitude)
            )
            onBoundsChange?(bounds)
        }
    }
}

private extension View {
    /// Cut a hole in this view using another view as a mask (for the selection window).
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask(
            ZStack {
                Rectangle().fill(Color.white)
                mask().blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}
