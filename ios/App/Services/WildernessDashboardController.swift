import Foundation
import Observation
import ConnectorKit
import LLMKit

/// Trail tab state: GPS, waypoints, breadcrumbs, offline map downloads, motion + AR capabilities.
@MainActor
@Observable
final class WildernessDashboardController {
    private(set) var fix: LocationFix?
    private(set) var waypoints: [WaypointInfo] = []
    private(set) var breadcrumbs: [BreadcrumbPoint] = []
    private(set) var packs: [OfflineMapPackInfo] = []
    private(set) var isRecordingTrail = false
    private(set) var downloadProgress: Double?
    private(set) var statusMessage: String?
    private(set) var isConnectorEnabled = false
    private(set) var permission: PermissionState = .notDetermined
    private(set) var motionCapabilities: MotionCapabilities = .none
    private(set) var arCapabilities: TrailARCapabilities = .none
    private(set) var motionSnapshot: MotionSedentarySnapshot?
    private(set) var isMotionConnected = false
    /// User preference for LiDAR mesh; ignored when hardware lacks LiDAR.
    private(set) var preferARMesh = false

    func setPreferARMesh(_ on: Bool) {
        preferARMesh = on && arCapabilities.depthMeshSupported
    }

    @ObservationIgnored private weak var connectors: ConnectorsModel?
    @ObservationIgnored private var locationProvider: (any LocationProvider)?
    @ObservationIgnored private var locationController: CoreLocationController?
    @ObservationIgnored private var motionProvider: (any MotionProvider)?
    @ObservationIgnored private var trail: (any TrailStore)?
    @ObservationIgnored private var mapStore: OfflineMapFileStore?
    @ObservationIgnored private var downloader: OfflineMapDownloader?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var trailObserver: NSObjectProtocol?

    /// Product warnings for missing sensors (Air without LiDAR, no pedometer, etc.).
    var sensorWarnings: [String] {
        var lines: [String] = []
        if isMotionConnected {
            lines.append(contentsOf: motionCapabilities.warnings.filter { !$0.hasPrefix("Device motion") })
        }
        lines.append(contentsOf: arCapabilities.warnings.filter {
            // Always surface LiDAR absence; only surface world-tracking if truly missing.
            $0.contains("LiDAR") || !arCapabilities.compassOverlaySupported
        })
        // Deduplicate while preserving order.
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    var canOpenAROverlay: Bool { arCapabilities.compassOverlaySupported }
    var canUseSedentary: Bool { motionCapabilities.sedentarySupported && isMotionConnected }

    func configure(
        connectors: ConnectorsModel,
        locationProvider: any LocationProvider,
        locationController: CoreLocationController?,
        motionProvider: (any MotionProvider)?,
        trail: any TrailStore,
        maps: OfflineMapFileStore
    ) {
        self.connectors = connectors
        self.locationProvider = locationProvider
        self.locationController = locationController
        self.motionProvider = motionProvider
        self.trail = trail
        self.mapStore = maps
        self.downloader = OfflineMapDownloader(store: maps)
        arCapabilities = TrailARCapabilityProbe.current()
        if preferARMesh && !arCapabilities.depthMeshSupported {
            preferARMesh = false
        }
        if trailObserver == nil, locationController != nil {
            trailObserver = NotificationCenter.default.addObserver(
                forName: CoreLocationController.didUpdateFix,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let fix = note.object as? LocationFix else { return }
                Task { @MainActor in
                    self?.fix = fix
                    if self?.isRecordingTrail == true {
                        await self?.trail?.appendBreadcrumb(
                            BreadcrumbPoint(latitude: fix.latitude, longitude: fix.longitude, timestamp: fix.timestamp)
                        )
                        await self?.reloadTrail()
                    }
                }
            }
        }
    }

    func refreshStatus() async {
        guard let connectors else { return }
        await connectors.refresh()
        let row = connectors.rows.first(where: { $0.id == "location" })
        isConnectorEnabled = row?.isEnabled == true && row?.status.isConnected == true
        permission = await locationProvider?.permission() ?? .notDetermined
        let motionRow = connectors.rows.first(where: { $0.id == "motion" })
        isMotionConnected = motionRow?.isEnabled == true && motionRow?.status.isConnected == true
        if let motionProvider {
            motionCapabilities = await motionProvider.capabilities()
        } else {
            motionCapabilities = .none
        }
        arCapabilities = TrailARCapabilityProbe.current()
        if preferARMesh && !arCapabilities.depthMeshSupported {
            preferARMesh = false
        }
        await reloadTrail()
        await reloadPacks()
        if canUseSedentary {
            await refreshMotion()
        } else {
            motionSnapshot = nil
        }
    }

    func connectLocation() async {
        guard let connectors else { return }
        await connectors.connect("location")
        await connectors.setEnabled("location", true)
        await refreshStatus()
    }

    func connectMotion() async {
        guard let connectors else { return }
        await connectors.connect("motion")
        await connectors.setEnabled("motion", true)
        await refreshStatus()
    }

    func refreshMotion() async {
        guard let motionProvider else {
            motionSnapshot = nil
            return
        }
        let caps = await motionProvider.capabilities()
        motionCapabilities = caps
        guard caps.sedentarySupported else {
            motionSnapshot = nil
            statusMessage = caps.features.first(where: { $0.id == "sedentary" })?.warningLine
            return
        }
        do {
            motionSnapshot = try await motionProvider.sedentarySnapshot()
        } catch {
            motionSnapshot = nil
            statusMessage = error.localizedDescription
        }
    }

    func refreshFix() async {
        do {
            guard let locationProvider else {
                statusMessage = "Location is not available."
                return
            }
            fix = try await locationProvider.currentFix()
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func reloadTrail() async {
        waypoints = await trail?.listWaypoints() ?? []
        breadcrumbs = await trail?.breadcrumbs() ?? []
    }

    func reloadPacks() async {
        packs = await mapStore?.packs() ?? []
    }

    func saveWaypoint(name: String, notes: String = "", useCurrentFix: Bool = true) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var lat = fix?.latitude
        var lon = fix?.longitude
        if useCurrentFix {
            if lat == nil || lon == nil {
                await refreshFix()
                lat = fix?.latitude
                lon = fix?.longitude
            }
        }
        guard let lat, let lon else {
            statusMessage = "Need a GPS fix to save this waypoint."
            return
        }
        let waypoint = WaypointInfo(name: trimmed, latitude: lat, longitude: lon, notes: notes)
        await trail?.upsertWaypoint(waypoint)
        await reloadTrail()
        statusMessage = "Saved \(trimmed)."
    }

    func deleteWaypoint(_ id: UUID) async {
        await trail?.deleteWaypoint(id: id)
        await reloadTrail()
    }

    func clearTrail() async {
        await trail?.clearBreadcrumbs()
        await reloadTrail()
    }

    func setRecording(_ on: Bool) {
        isRecordingTrail = on
        if on {
            locationController?.startUpdating()
        } else {
            locationController?.stopUpdating()
        }
    }

    func downloadPackAroundHere(name: String) async {
        await refreshFix()
        guard let fix else {
            statusMessage = "Need a GPS fix before downloading a map pack."
            return
        }
        let pack = OfflineMapDownloader.region(around: fix, name: name.isEmpty ? "Around me" : name)
        await startDownload(pack)
    }

    func downloadPack(_ pack: OfflineMapPackInfo) async {
        await startDownload(pack)
    }

    func renamePack(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var pack = packs.first(where: { $0.id == id }) else { return }
        pack.name = trimmed
        pack.updatedAt = Date()
        await mapStore?.savePack(pack)
        await reloadPacks()
    }

    func redownloadPack(_ id: UUID) async {
        guard let pack = packs.first(where: { $0.id == id }) else { return }
        await startDownload(pack)
    }

    func deletePack(_ id: UUID) async {
        do {
            try await mapStore?.deletePack(id: id)
            await reloadPacks()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Total bytes of ready packs (for the offline maps manager).
    var offlineMapsStorageLine: String {
        let ready = packs.filter { $0.status == .ready }
        let bytes = ready.map(\.byteSize).reduce(0, +)
        if bytes <= 0 { return "No maps downloaded" }
        let mb = Double(bytes) / 1_048_576
        let size = String(format: mb < 10 ? "%.1f" : "%.0f", mb)
        return "\(ready.count) areas · \(size) MB on this iPhone"
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = nil
    }

    func askPrompt(kind: AskKind) -> String {
        switch kind {
        case .whereAmI:
            return "Where am I right now? Use location_current and give coordinates and accuracy. Do not invent a place name."
        case .bearingHome:
            return "Using location_bearing, what is the distance and compass bearing to my waypoint named Car? If I have no Car waypoint, say so."
        case .weatherHere:
            return "What is the weather here? Use weather_forecast with location here. If offline, use the cache."
        case .maps:
            return "Which offline map packs do I have? Use location_list_map_packs."
        case .sedentary:
            return "Have I been sitting too long? Use motion_sedentary and motion_capabilities. Be gentle; not medical advice. Mention any disabled sensors."
        }
    }

    enum AskKind {
        case whereAmI, bearingHome, weatherHere, maps, sedentary
    }

    private func startDownload(_ pack: OfflineMapPackInfo) async {
        guard let downloader else { return }
        downloadTask?.cancel()
        downloadProgress = 0
        statusMessage = "Downloading offline map…"
        downloadTask = Task {
            do {
                _ = try OfflineMapDownloader.validate(
                    minLat: pack.minLatitude, minLon: pack.minLongitude,
                    maxLat: pack.maxLatitude, maxLon: pack.maxLongitude,
                    minZoom: pack.minZoom, maxZoom: pack.maxZoom
                )
                let finished = try await downloader.download(pack: pack) { [weak self] value in
                    await MainActor.run { self?.downloadProgress = value }
                }
                await reloadPacks()
                statusMessage = finished.status == .ready
                    ? "Offline map “\(finished.name)” ready (\(finished.sizeLine))."
                    : "Download finished with status \(finished.status.rawValue)."
                // Clear progress after status so the download sheet can dismiss on success.
                downloadProgress = nil
            } catch is CancellationError {
                statusMessage = "Download cancelled."
                downloadProgress = nil
                await reloadPacks()
            } catch {
                statusMessage = error.localizedDescription
                downloadProgress = nil
                await reloadPacks()
            }
        }
    }
}
