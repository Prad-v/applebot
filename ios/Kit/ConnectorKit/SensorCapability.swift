import Foundation

/// One gated sensor-backed feature. When unavailable, the UI shows `unavailableReason`
/// and disables only that feature — other sensors keep working.
public struct SensorFeatureStatus: Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var isAvailable: Bool
    /// Shown when `isAvailable` is false. Written for the end user.
    public var unavailableReason: String?

    public init(
        id: String,
        displayName: String,
        isAvailable: Bool,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
    }

    /// Banner / toast line when this feature cannot run.
    public var warningLine: String? {
        guard !isAvailable else { return nil }
        if let unavailableReason, !unavailableReason.isEmpty {
            return "\(displayName): \(unavailableReason)"
        }
        return "\(displayName) is not available on this iPhone."
    }
}

/// Core Motion capabilities that power the sedentary / activity tool.
public struct MotionCapabilities: Sendable, Equatable, Hashable {
    public var deviceMotion: Bool
    public var pedometer: Bool
    public var activity: Bool
    public var relativeAltitude: Bool

    public init(
        deviceMotion: Bool = false,
        pedometer: Bool = false,
        activity: Bool = false,
        relativeAltitude: Bool = false
    ) {
        self.deviceMotion = deviceMotion
        self.pedometer = pedometer
        self.activity = activity
        self.relativeAltitude = relativeAltitude
    }

    /// Soft sedentary check needs at least pedometer or activity classification.
    public var sedentarySupported: Bool { pedometer || activity }

    public var features: [SensorFeatureStatus] {
        [
            SensorFeatureStatus(
                id: "device-motion",
                displayName: "Device motion (accelerometer + gyro)",
                isAvailable: deviceMotion,
                unavailableReason: "High‑g accelerometer / gyro motion fusion is unavailable on this device."
            ),
            SensorFeatureStatus(
                id: "pedometer",
                displayName: "Step counting",
                isAvailable: pedometer,
                unavailableReason: "The pedometer is unavailable, so step-based sedentary checks are disabled."
            ),
            SensorFeatureStatus(
                id: "activity",
                displayName: "Motion activity",
                isAvailable: activity,
                unavailableReason: "Walking / stationary classification is unavailable on this device."
            ),
            SensorFeatureStatus(
                id: "relative-altitude",
                displayName: "Barometer altitude",
                isAvailable: relativeAltitude,
                unavailableReason: "Relative altitude (barometer) is unavailable — floor / elevation change is disabled."
            ),
            SensorFeatureStatus(
                id: "sedentary",
                displayName: "Sedentary check",
                isAvailable: sedentarySupported,
                unavailableReason: "Needs step counting or motion activity. Connect Motion or use a device that supports Core Motion."
            ),
        ]
    }

    public var warnings: [String] {
        features.compactMap(\.warningLine)
    }

    /// Fully capable device (typical modern iPhone).
    public static let allAvailable = MotionCapabilities(
        deviceMotion: true, pedometer: true, activity: true, relativeAltitude: true
    )

    /// Nothing usable (simulator / restricted).
    public static let none = MotionCapabilities()
}

/// ARKit trail overlay capabilities. LiDAR mesh is Pro-only; world tracking still works on Air.
public struct TrailARCapabilities: Sendable, Equatable, Hashable {
    public var worldTracking: Bool
    public var lidarMesh: Bool
    public var sceneDepth: Bool

    public init(
        worldTracking: Bool = false,
        lidarMesh: Bool = false,
        sceneDepth: Bool = false
    ) {
        self.worldTracking = worldTracking
        self.lidarMesh = lidarMesh
        self.sceneDepth = sceneDepth
    }

    public var compassOverlaySupported: Bool { worldTracking }
    public var depthMeshSupported: Bool { lidarMesh }

    public var features: [SensorFeatureStatus] {
        [
            SensorFeatureStatus(
                id: "ar-world-tracking",
                displayName: "AR trail overlay",
                isAvailable: worldTracking,
                unavailableReason: "ARKit world tracking is unavailable on this device — the compass AR overlay is disabled."
            ),
            SensorFeatureStatus(
                id: "lidar-mesh",
                displayName: "LiDAR depth mesh",
                isAvailable: lidarMesh,
                unavailableReason: "LiDAR is not on this iPhone (for example iPhone Air). Depth mesh is disabled; compass AR overlay still works when AR is available."
            ),
            SensorFeatureStatus(
                id: "scene-depth",
                displayName: "Scene depth frames",
                isAvailable: sceneDepth,
                unavailableReason: "Scene depth is unavailable without LiDAR / supported AR hardware."
            ),
        ]
    }

    public var warnings: [String] {
        features.compactMap(\.warningLine)
    }

    public static let proFull = TrailARCapabilities(worldTracking: true, lidarMesh: true, sceneDepth: true)
    public static let airNoLidar = TrailARCapabilities(worldTracking: true, lidarMesh: false, sceneDepth: false)
    public static let none = TrailARCapabilities()
}

/// Surroundings / scene-description capabilities (accessibility).
public struct SurroundingsCapabilities: Sendable, Equatable, Hashable {
    public var camera: Bool
    public var onDeviceVision: Bool
    public var lidarDepthAssist: Bool

    public init(camera: Bool = true, onDeviceVision: Bool = true, lidarDepthAssist: Bool = false) {
        self.camera = camera
        self.onDeviceVision = onDeviceVision
        self.lidarDepthAssist = lidarDepthAssist
    }

    /// Basic describe flow needs camera + Vision (model narration is separate).
    public var describeSupported: Bool { camera && onDeviceVision }

    public var features: [SensorFeatureStatus] {
        [
            SensorFeatureStatus(
                id: "surroundings-camera",
                displayName: "Camera",
                isAvailable: camera,
                unavailableReason: "Camera access is required to describe surroundings."
            ),
            SensorFeatureStatus(
                id: "surroundings-vision",
                displayName: "On-device Vision",
                isAvailable: onDeviceVision,
                unavailableReason: "On-device scene analysis is unavailable on this device."
            ),
            SensorFeatureStatus(
                id: "surroundings-lidar",
                displayName: "LiDAR depth assist",
                isAvailable: lidarDepthAssist,
                unavailableReason: "LiDAR is not on this iPhone. Distance hints are limited; camera description still works."
            ),
            SensorFeatureStatus(
                id: "surroundings-describe",
                displayName: "Describe surroundings",
                isAvailable: describeSupported,
                unavailableReason: "Needs camera and on-device Vision to describe the scene."
            ),
        ]
    }

    public var warnings: [String] {
        features.compactMap(\.warningLine)
    }

    public static let airTypical = SurroundingsCapabilities(
        camera: true, onDeviceVision: true, lidarDepthAssist: false
    )
    public static let proTypical = SurroundingsCapabilities(
        camera: true, onDeviceVision: true, lidarDepthAssist: true
    )
    public static let none = SurroundingsCapabilities(
        camera: false, onDeviceVision: false, lidarDepthAssist: false
    )
}

/// 3D room scan (RoomPlan) capabilities — LiDAR Pro devices only for a real scan.
public struct RoomScanCapabilities: Sendable, Equatable, Hashable {
    public var roomPlanSupported: Bool
    public var lidarAvailable: Bool

    public init(roomPlanSupported: Bool = false, lidarAvailable: Bool = false) {
        self.roomPlanSupported = roomPlanSupported
        self.lidarAvailable = lidarAvailable
    }

    public var scanSupported: Bool { roomPlanSupported }

    public var features: [SensorFeatureStatus] {
        [
            SensorFeatureStatus(
                id: "roomplan",
                displayName: "RoomPlan 3D scan",
                isAvailable: roomPlanSupported,
                unavailableReason: "Room scanning needs an iPhone or iPad with LiDAR (for example iPhone Pro). This device cannot run RoomPlan."
            ),
            SensorFeatureStatus(
                id: "roomplan-lidar",
                displayName: "LiDAR for room scan",
                isAvailable: lidarAvailable,
                unavailableReason: "LiDAR is not on this iPhone (for example iPhone Air). 3D room scan is disabled."
            ),
        ]
    }

    public var warnings: [String] {
        features.compactMap(\.warningLine)
    }

    public static let proTypical = RoomScanCapabilities(roomPlanSupported: true, lidarAvailable: true)
    public static let airTypical = RoomScanCapabilities(roomPlanSupported: false, lidarAvailable: false)
    public static let none = RoomScanCapabilities()
}

/// Builds user-facing warning lines for a set of gated features (only unavailable ones).
public enum SensorCapability {
    public static func warnings(from features: [SensorFeatureStatus]) -> [String] {
        features.compactMap(\.warningLine)
    }

    /// Features that product UI should treat as hard-disabled.
    public static func disabledIDs(from features: [SensorFeatureStatus]) -> Set<String> {
        Set(features.filter { !$0.isAvailable }.map(\.id))
    }
}
