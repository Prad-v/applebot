import Foundation
import ConnectorKit

#if canImport(ARKit)
import ARKit
#endif

/// Probes ARKit / LiDAR support for the Trail AR overlay.
///
/// iPhone Air and other non-Pro models typically have world tracking but not LiDAR mesh.
enum TrailARCapabilityProbe {
    static func current() -> TrailARCapabilities {
        #if canImport(ARKit)
        let world = ARWorldTrackingConfiguration.isSupported
        let mesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        let depth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
        return TrailARCapabilities(
            worldTracking: world,
            lidarMesh: mesh,
            sceneDepth: depth
        )
        #else
        return .none
        #endif
    }
}
