import Foundation
import ConnectorKit

#if canImport(RoomPlan)
import RoomPlan
#endif
#if canImport(ARKit)
import ARKit
#endif

enum RoomScanCapabilityProbe {
    static func current() -> RoomScanCapabilities {
        #if canImport(RoomPlan)
        let roomPlan = RoomCaptureSession.isSupported
        #else
        let roomPlan = false
        #endif
        #if canImport(ARKit)
        let lidar = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        #else
        let lidar = false
        #endif
        // RoomPlan already implies LiDAR-capable hardware when supported.
        return RoomScanCapabilities(
            roomPlanSupported: roomPlan,
            lidarAvailable: lidar || roomPlan
        )
    }
}
