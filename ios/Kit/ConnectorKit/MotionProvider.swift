import Foundation

/// Coarse activity classification from Core Motion (or a test double).
public enum MotionActivityKind: String, Sendable, Equatable, Codable, CaseIterable {
    case unknown
    case stationary
    case walking
    case running
    case cycling
    case automotive

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .stationary: return "Stationary"
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .automotive: return "In a vehicle"
        }
    }
}

/// Snapshot used by the sedentary tool and Trail activity card.
public struct MotionSedentarySnapshot: Sendable, Equatable {
    public var activity: MotionActivityKind
    public var stepsLastTwoHours: Int?
    public var stepsToday: Int?
    public var floorsAscended: Int?
    public var relativeAltitudeMeters: Double?
    public var sedentaryLikely: Bool
    public var note: String
    public var capabilities: MotionCapabilities
    public var timestamp: Date

    public init(
        activity: MotionActivityKind = .unknown,
        stepsLastTwoHours: Int? = nil,
        stepsToday: Int? = nil,
        floorsAscended: Int? = nil,
        relativeAltitudeMeters: Double? = nil,
        sedentaryLikely: Bool = false,
        note: String = "",
        capabilities: MotionCapabilities = .none,
        timestamp: Date = Date()
    ) {
        self.activity = activity
        self.stepsLastTwoHours = stepsLastTwoHours
        self.stepsToday = stepsToday
        self.floorsAscended = floorsAscended
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.sedentaryLikely = sedentaryLikely
        self.note = note
        self.capabilities = capabilities
        self.timestamp = timestamp
    }
}

/// Source of Core Motion summaries. `CoreMotionStoreProvider` is the real one; `InMemoryMotionProvider` for tests.
public protocol MotionProvider: Sendable {
    func capabilities() async -> MotionCapabilities
    func permission() async -> PermissionState
    func requestAccess() async throws -> Bool
    func sedentarySnapshot() async throws -> MotionSedentarySnapshot
}

public actor InMemoryMotionProvider: MotionProvider {
    private var state: PermissionState
    private var caps: MotionCapabilities
    private var snapshot: MotionSedentarySnapshot
    private let grantOnRequest: Bool

    public init(
        permission: PermissionState = .authorized,
        capabilities: MotionCapabilities = .allAvailable,
        snapshot: MotionSedentarySnapshot = MotionSedentarySnapshot(
            activity: .stationary,
            stepsLastTwoHours: 40,
            stepsToday: 1_200,
            floorsAscended: 0,
            sedentaryLikely: true,
            note: "Few steps in the last two hours while stationary.",
            capabilities: .allAvailable
        ),
        grantOnRequest: Bool = true
    ) {
        self.state = permission
        self.caps = capabilities
        var copy = snapshot
        copy.capabilities = capabilities
        self.snapshot = copy
        self.grantOnRequest = grantOnRequest
    }

    public func capabilities() -> MotionCapabilities { caps }

    public func permission() -> PermissionState { state }

    public func requestAccess() -> Bool {
        if state == .notDetermined { state = grantOnRequest ? .authorized : .denied }
        return state == .authorized
    }

    public func sedentarySnapshot() throws -> MotionSedentarySnapshot {
        guard caps.sedentarySupported else {
            throw ConnectorError.notConfigured(
                "Sedentary check needs step counting or motion activity. That hardware or API is not available on this device."
            )
        }
        guard state == .authorized else {
            throw ConnectorError.permissionDenied(
                "Motion access has not been granted. Connect Motion in You → Connectors, then allow Motion & Fitness for Applebot in Settings."
            )
        }
        var copy = snapshot
        copy.capabilities = caps
        return copy
    }

    public func setPermission(_ state: PermissionState) { self.state = state }
    public func setCapabilities(_ capabilities: MotionCapabilities) {
        caps = capabilities
        snapshot.capabilities = capabilities
    }
    public func setSnapshot(_ snapshot: MotionSedentarySnapshot) {
        var copy = snapshot
        copy.capabilities = caps
        self.snapshot = copy
    }
}
