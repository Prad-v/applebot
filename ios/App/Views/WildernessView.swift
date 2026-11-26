import SwiftUI
import ConnectorKit
import LLMKit

/// Trail tab: GPS, waypoints, breadcrumb trail, offline OpenTopoMap packs.
struct WildernessView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showAddWaypoint = false
    @State private var waypointName = "Car"
    @State private var showDownload = false
    @State private var showAROverlay = false
    @State private var renamingPack: OfflineMapPackInfo?
    @State private var renameDraft = ""

    private var trail: WildernessDashboardController { environment.wilderness }

    var body: some View {
        NavigationStack {
            Group {
                if !trail.isConnectorEnabled {
                    enablePrompt
                } else {
                    dashboard
                }
            }
            .applebotCanvas()
            .navigationTitle("Trail")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if trail.isConnectorEnabled {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                showAddWaypoint = true
                            } label: {
                                Label("Save waypoint", systemImage: "mappin.and.ellipse")
                            }
                            Button {
                                showDownload = true
                            } label: {
                                Label("Download offline map", systemImage: "arrow.down.circle")
                            }
                            Button {
                                showAROverlay = true
                            } label: {
                                Label("AR trail overlay", systemImage: "camera.viewfinder")
                            }
                            .disabled(!trail.canOpenAROverlay)
                            Button {
                                Task { await trail.refreshFix() }
                            } label: {
                                Label("Refresh GPS", systemImage: "location")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("trail-options")
                    }
                }
            }
            .task {
                await trail.refreshStatus()
                if trail.isConnectorEnabled {
                    await trail.refreshFix()
                }
            }
            .sheet(isPresented: $showAddWaypoint) {
                addWaypointSheet
            }
            .fullScreenCover(isPresented: $showDownload) {
                OfflineMapDownloadSheet()
            }
            .fullScreenCover(isPresented: $showAROverlay) {
                ARTrailOverlayView(
                    fix: trail.fix,
                    waypoints: trail.waypoints,
                    capabilities: trail.arCapabilities,
                    preferMesh: Binding(
                        get: { trail.preferARMesh },
                        set: { trail.setPreferARMesh($0) }
                    )
                )
            }
            .sheet(item: $renamingPack) { pack in
                renameSheet(pack)
            }
        }
    }

    private var enablePrompt: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ApplebotTheme.spaceL) {
                ApplebotHeroEmpty(
                    symbol: "map",
                    title: "Find your way offline",
                    message: "Connect Location for GPS, waypoints, a breadcrumb trail, and offline topographic map packs — built for weak or no signal in the wilderness.",
                    primaryTitle: "Connect Location",
                    primarySystemImage: "location.north.line",
                    primaryAction: {
                        Task { await trail.connectLocation() }
                    }
                )
                Text("GPS works without cell service. Download an offline map while you still have signal — pan the map like Google Maps, then download. Weather can use “here” and a cached forecast.")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
            }
            .padding(ApplebotTheme.spaceL)
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ApplebotTheme.spaceL) {
                sensorWarningsCard
                mapCard
                gpsCard
                motionCard
                arCard
                recordingCard
                waypointsCard
                packsCard
                askCard
                if let status = trail.statusMessage {
                    Text(status)
                        .font(ApplebotTheme.footnote())
                        .foregroundStyle(ApplebotTheme.secondaryInk)
                }
                Text(OfflineMapDownloader.attribution)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(ApplebotTheme.spaceL)
        }
    }

    @ViewBuilder
    private var sensorWarningsCard: some View {
        let warnings = trail.sensorWarnings
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Sensor notes", systemImage: "exclamationmark.triangle")
                    .font(ApplebotTheme.title())
                ForEach(warnings, id: \.self) { line in
                    Text(line)
                        .font(ApplebotTheme.footnote())
                        .foregroundStyle(ApplebotTheme.secondaryInk)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("trail-sensor-warnings")
        }
    }

    private var motionCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            Text("Motion / sedentary")
                .font(ApplebotTheme.title())
            if !trail.motionCapabilities.sedentarySupported {
                Text(
                    trail.motionCapabilities.features.first(where: { $0.id == "sedentary" })?.unavailableReason
                        ?? "Sedentary check is unavailable on this device."
                )
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
            } else if !trail.isMotionConnected {
                Text("Connect Motion for a soft sedentary check from the pedometer and activity sensors.")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
                ApplebotSecondaryButton(title: "Connect Motion", systemImage: "figure.walk.motion") {
                    Task { await trail.connectMotion() }
                }
            } else if let snap = trail.motionSnapshot {
                Text(snap.activity.displayName)
                    .font(.headline)
                if let steps = snap.stepsLastTwoHours {
                    Text("\(steps) steps in the last ~2 hours")
                        .font(ApplebotTheme.footnote())
                        .foregroundStyle(ApplebotTheme.secondaryInk)
                }
                Text(snap.sedentaryLikely ? "Sedentary likely — a short walk may help." : "Looking active enough right now.")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
                HStack {
                    Button("Refresh") {
                        Task { await trail.refreshMotion() }
                    }
                    .buttonStyle(.bordered)
                    Button("Ask Applebot") {
                        environment.askInChat(trail.askPrompt(kind: .sedentary))
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Motion is connected. Pull a snapshot when you want a sedentary check.")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
                Button("Check now") {
                    Task { await trail.refreshMotion() }
                }
                .buttonStyle(.bordered)
            }
        }
        .accessibilityIdentifier("trail-motion")
    }

    private var arCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            Text("AR trail overlay")
                .font(ApplebotTheme.title())
            if trail.canOpenAROverlay {
                Text(
                    trail.arCapabilities.depthMeshSupported
                        ? "Camera overlay with waypoint bearings. LiDAR depth mesh is available on this iPhone."
                        : "Camera overlay with waypoint bearings. LiDAR depth mesh is disabled on this iPhone (no LiDAR)."
                )
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
                ApplebotSecondaryButton(title: "Open AR overlay", systemImage: "camera.viewfinder") {
                    showAROverlay = true
                }
            } else {
                Text(
                    trail.arCapabilities.features.first(where: { $0.id == "ar-world-tracking" })?.unavailableReason
                        ?? "AR trail overlay is not available on this device."
                )
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
                ApplebotSecondaryButton(title: "Open AR overlay", systemImage: "camera.viewfinder") {}
                    .disabled(true)
            }
        }
        .accessibilityIdentifier("trail-ar")
    }

    private var mapCard: some View {
        WildernessMapView(
            fix: trail.fix,
            waypoints: trail.waypoints,
            breadcrumbs: trail.breadcrumbs,
            packs: trail.packs,
            mapStore: environment.offlineMapStore
        )
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("trail-map")
    }

    private var gpsCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            Text("Position")
                .font(ApplebotTheme.title())
            if let fix = trail.fix {
                Text(fix.coordinateLine)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                HStack {
                    if let accuracy = fix.horizontalAccuracyMeters {
                        Label("±\(Int(accuracy)) m", systemImage: "scope")
                    }
                    if let altitude = fix.altitudeMeters {
                        Label("\(Int(altitude)) m", systemImage: "mountain.2")
                    }
                }
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
            } else {
                Text("Waiting for GPS…")
                    .foregroundStyle(ApplebotTheme.secondaryInk)
            }
        }
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            Toggle(isOn: Binding(
                get: { trail.isRecordingTrail },
                set: { trail.setRecording($0) }
            )) {
                Text("Record breadcrumb trail")
            }
            .accessibilityIdentifier("trail-record")
            Text("\(trail.breadcrumbs.count) points on this iPhone")
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
            if !trail.breadcrumbs.isEmpty {
                Button("Clear trail", role: .destructive) {
                    Task { await trail.clearTrail() }
                }
            }
        }
    }

    private var waypointsCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            Text("Waypoints")
                .font(ApplebotTheme.title())
            if trail.waypoints.isEmpty {
                Text("Save Car, Camp, or Trailhead while you still know where they are.")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
            } else {
                ForEach(trail.waypoints) { waypoint in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(waypoint.name).font(.headline)
                            Text(LocationFix(latitude: waypoint.latitude, longitude: waypoint.longitude).coordinateLine)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await trail.deleteWaypoint(waypoint.id) }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }

    private var packsCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            HStack {
                Text("Offline maps")
                    .font(ApplebotTheme.title())
                Spacer()
                Button {
                    showDownload = true
                } label: {
                    Label("Download", systemImage: "plus.circle.fill")
                        .font(ApplebotTheme.footnote().weight(.semibold))
                }
                .accessibilityIdentifier("trail-download-map")
            }
            Text(trail.offlineMapsStorageLine)
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)

            if let progress = trail.downloadProgress {
                ProgressView(value: progress) {
                    Text("Downloading… \(Int(progress * 100))%")
                        .font(ApplebotTheme.footnote())
                }
                Button("Cancel download") { trail.cancelDownload() }
            }

            if trail.packs.isEmpty {
                Text("Choose an area on the map (like Google Maps), then download topographic tiles before you lose signal.")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
            } else {
                ForEach(trail.packs) { pack in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.name).font(.headline)
                                Text(statusLine(for: pack))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button("Rename") {
                                    renameDraft = pack.name
                                    renamingPack = pack
                                }
                                Button("Update download") {
                                    Task { await trail.redownloadPack(pack.id) }
                                }
                                Button("Delete", role: .destructive) {
                                    Task { await trail.deletePack(pack.id) }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                        if pack.status == .failed, let error = pack.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func statusLine(for pack: OfflineMapPackInfo) -> String {
        switch pack.status {
        case .ready: return "Ready · \(pack.sizeLine)"
        case .downloading: return "Downloading…"
        case .failed: return "Failed · tap ⋯ to retry"
        case .empty: return "Not downloaded"
        }
    }

    private var askCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            Text("Ask Applebot")
                .font(ApplebotTheme.title())
            VStack(spacing: 8) {
                askButton("Where am I?", kind: .whereAmI)
                askButton("Bearing to Car", kind: .bearingHome)
                askButton("Weather here", kind: .weatherHere)
                askButton("My offline maps", kind: .maps)
                askButton("Have I been sitting too long?", kind: .sedentary)
            }
        }
    }

    private func askButton(_ title: String, kind: WildernessDashboardController.AskKind) -> some View {
        Button {
            environment.askInChat(trail.askPrompt(kind: kind))
        } label: {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var addWaypointSheet: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $waypointName)
                Text("Uses your current GPS fix.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Waypoint")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddWaypoint = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await trail.saveWaypoint(name: waypointName)
                            showAddWaypoint = false
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func renameSheet(_ pack: OfflineMapPackInfo) -> some View {
        NavigationStack {
            Form {
                TextField("Name", text: $renameDraft)
            }
            .navigationTitle("Rename map")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { renamingPack = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await trail.renamePack(pack.id, to: renameDraft)
                            renamingPack = nil
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
