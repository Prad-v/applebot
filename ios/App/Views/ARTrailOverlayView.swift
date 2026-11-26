import SwiftUI
import ConnectorKit

#if canImport(ARKit)
import ARKit
import SceneKit
#endif

/// Trail AR overlay: compass / waypoint HUD on camera. LiDAR mesh is optional (Pro only).
struct ARTrailOverlayView: View {
    let fix: LocationFix?
    let waypoints: [WaypointInfo]
    let capabilities: TrailARCapabilities
    @Binding var preferMesh: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                #if canImport(ARKit)
                if capabilities.compassOverlaySupported {
                    ARTrailCameraRepresentable(
                        enableMesh: preferMesh && capabilities.depthMeshSupported
                    )
                    .ignoresSafeArea()
                } else {
                    unavailablePlaceholder
                }
                #else
                unavailablePlaceholder
                #endif

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(activeWarnings, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .font(ApplebotTheme.footnote())
                            .foregroundStyle(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    hudCard
                }
                .padding(ApplebotTheme.spaceM)
            }
            .navigationTitle("AR trail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                meshToggleBar
            }
        }
    }

    private var activeWarnings: [String] {
        var lines: [String] = []
        if !capabilities.compassOverlaySupported {
            lines.append(
                capabilities.features.first(where: { $0.id == "ar-world-tracking" })?.warningLine
                    ?? "AR trail overlay is not available on this device."
            )
        }
        if !capabilities.depthMeshSupported,
           let meshWarning = capabilities.features.first(where: { $0.id == "lidar-mesh" })?.warningLine {
            lines.append(meshWarning)
        }
        return lines
    }

    private var hudCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fix {
                Text(fix.coordinateLine)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                if let course = fix.courseDegrees {
                    Text(String(format: "Course %.0f° (%@)", course, GeoMath.cardinal(forBearingDegrees: course)))
                        .font(ApplebotTheme.footnote())
                }
            } else {
                Text("Waiting for GPS…")
                    .font(ApplebotTheme.footnote())
            }
            if waypoints.isEmpty {
                Text("No waypoints yet — save Car / Camp on the Trail tab.")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(.secondary)
            } else if let fix {
                ForEach(waypoints.prefix(4)) { waypoint in
                    let bearing = GeoMath.bearingDegrees(
                        fromLat: fix.latitude, fromLon: fix.longitude,
                        toLat: waypoint.latitude, toLon: waypoint.longitude
                    )
                    let meters = GeoMath.distanceMeters(
                        fromLat: fix.latitude, fromLon: fix.longitude,
                        toLat: waypoint.latitude, toLon: waypoint.longitude
                    )
                    Text("\(waypoint.name): \(Int(meters)) m · \(Int(bearing))° \(GeoMath.cardinal(forBearingDegrees: bearing))")
                        .font(ApplebotTheme.footnote())
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var meshToggleBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { preferMesh && capabilities.depthMeshSupported },
                set: { newValue in
                    preferMesh = newValue && capabilities.depthMeshSupported
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LiDAR depth mesh")
                    Text(
                        capabilities.depthMeshSupported
                            ? "Show environment mesh from the LiDAR scanner"
                            : "Unavailable without LiDAR — toggle disabled"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .disabled(!capabilities.depthMeshSupported)
            .accessibilityIdentifier("ar-lidar-mesh-toggle")
        }
        .padding()
        .background(.bar)
    }

    private var unavailablePlaceholder: some View {
        VStack(spacing: ApplebotTheme.spaceM) {
            Image(systemName: "camera.metering.unknown")
                .font(.largeTitle)
            Text("AR trail overlay unavailable")
                .font(ApplebotTheme.title())
            Text(
                capabilities.features.first(where: { $0.id == "ar-world-tracking" })?.unavailableReason
                    ?? "ARKit world tracking is not supported on this device."
            )
            .font(ApplebotTheme.footnote())
            .foregroundStyle(ApplebotTheme.secondaryInk)
            .multilineTextAlignment(.center)
        }
        .padding(ApplebotTheme.spaceL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .applebotCanvas()
    }
}

#if canImport(ARKit)
private struct ARTrailCameraRepresentable: UIViewRepresentable {
    var enableMesh: Bool

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = true
        view.session = context.coordinator.session
        context.coordinator.apply(to: view, mesh: enableMesh)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.apply(to: uiView, mesh: enableMesh)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        coordinator.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let session = ARSession()
        private var lastMesh: Bool?

        func apply(to view: ARSCNView, mesh: Bool) {
            guard ARWorldTrackingConfiguration.isSupported else { return }
            if lastMesh == mesh { return }
            lastMesh = mesh

            let config = ARWorldTrackingConfiguration()
            config.worldAlignment = .gravityAndHeading
            if mesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
                // ARSCNView has no RealityKit `.showSceneUnderstanding`; feature points
                // confirm tracking while LiDAR mesh runs for occlusion / reconstruction.
                view.debugOptions = [ARSCNDebugOptions.showFeaturePoints]
            } else {
                view.debugOptions = []
            }
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }

        func pause() {
            session.pause()
        }
    }
}
#endif
