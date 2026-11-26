#if canImport(CoreMotion)
import Foundation
import CoreMotion

/// `MotionProvider` backed by Core Motion on Apple platforms.
///
/// Requires `NSMotionUsageDescription` in Info.plist. Pedometer / activity APIs
/// trigger the Motion & Fitness permission sheet on first use.
public final class CoreMotionStoreProvider: MotionProvider, @unchecked Sendable {
    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()
    private let lock = NSLock()
    private var relativeAltitudeMeters: Double?
    private var altimeterStarted = false

    public init() {}

    public func capabilities() async -> MotionCapabilities {
        MotionCapabilities(
            deviceMotion: motionManager.isDeviceMotionAvailable,
            pedometer: CMPedometer.isStepCountingAvailable(),
            activity: CMMotionActivityManager.isActivityAvailable(),
            relativeAltitude: CMAltimeter.isRelativeAltitudeAvailable()
        )
    }

    public func permission() async -> PermissionState {
        // Core Motion does not expose a fine-grained status API for all sensors.
        // We treat "not yet requested" as notDetermined until the first successful read
        // after connect(); denied/restricted surfaces as errors from the OS.
        let status = CMMotionActivityManager.authorizationStatus()
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func requestAccess() async throws -> Bool {
        let caps = await capabilities()
        guard caps.sedentarySupported else { return false }

        if caps.activity {
            return try await withCheckedThrowingContinuation { continuation in
                // Querying recent activity presents the system permission sheet when needed.
                let from = Date().addingTimeInterval(-60)
                activityManager.queryActivityStarting(from: from, to: Date(), to: .main) { _, error in
                    if let error {
                        let ns = error as NSError
                        if ns.domain == CMErrorDomain {
                            continuation.resume(returning: false)
                            return
                        }
                        _ = error
                    }
                    let status = CMMotionActivityManager.authorizationStatus()
                    continuation.resume(returning: status == .authorized)
                }
            }
        }

        if caps.pedometer {
            return try await withCheckedThrowingContinuation { continuation in
                let from = Date().addingTimeInterval(-60)
                pedometer.queryPedometerData(from: from, to: Date()) { _, error in
                    if let error {
                        let ns = error as NSError
                        if ns.domain == CMErrorDomain {
                            continuation.resume(returning: false)
                            return
                        }
                        _ = error
                    }
                    continuation.resume(returning: true)
                }
            }
        }

        return false
    }

    public func sedentarySnapshot() async throws -> MotionSedentarySnapshot {
        let caps = await capabilities()
        guard caps.sedentarySupported else {
            throw ConnectorError.notConfigured(
                "Sedentary check needs step counting or motion activity. That is not available on this device."
            )
        }

        let permission = await permission()
        if permission == .denied || permission == .restricted {
            throw ConnectorError.permissionDenied(
                "Motion access was denied. Allow Motion & Fitness for Applebot in the Settings app."
            )
        }

        async let activity = fetchActivity(available: caps.activity)
        async let steps2h = fetchSteps(hoursBack: 2, available: caps.pedometer)
        async let stepsToday = fetchStepsToday(available: caps.pedometer)
        async let floors = fetchFloorsToday(available: caps.pedometer)
        startAltimeterIfNeeded(available: caps.relativeAltitude)

        let kind = await activity
        let lastTwo = await steps2h
        let today = await stepsToday
        let floorsAscended = await floors
        let altitude = currentRelativeAltitude()

        let (likely, note) = MotionConnector.evaluateSedentary(
            activity: kind,
            stepsLastTwoHours: lastTwo,
            capabilities: caps
        )

        return MotionSedentarySnapshot(
            activity: kind,
            stepsLastTwoHours: lastTwo,
            stepsToday: today,
            floorsAscended: floorsAscended,
            relativeAltitudeMeters: altitude,
            sedentaryLikely: likely,
            note: note,
            capabilities: caps,
            timestamp: Date()
        )
    }

    // MARK: Private

    private func fetchActivity(available: Bool) async -> MotionActivityKind {
        guard available else { return .unknown }
        return await withCheckedContinuation { continuation in
            let from = Date().addingTimeInterval(-10 * 60)
            activityManager.queryActivityStarting(from: from, to: Date(), to: .main) { activities, _ in
                let latest = activities?.last
                continuation.resume(returning: Self.mapActivity(latest))
            }
        }
    }

    private func fetchSteps(hoursBack: Double, available: Bool) async -> Int? {
        guard available else { return nil }
        let to = Date()
        let from = to.addingTimeInterval(-hoursBack * 3600)
        return await querySteps(from: from, to: to)
    }

    private func fetchStepsToday(available: Bool) async -> Int? {
        guard available else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return await querySteps(from: start, to: Date())
    }

    private func fetchFloorsToday(available: Bool) async -> Int? {
        guard available, CMPedometer.isFloorCountingAvailable() else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: Date()) { data, _ in
                continuation.resume(returning: data?.floorsAscended?.intValue)
            }
        }
    }

    private func querySteps(from: Date, to: Date) async -> Int? {
        await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: from, to: to) { data, _ in
                continuation.resume(returning: data?.numberOfSteps.intValue)
            }
        }
    }

    private func startAltimeterIfNeeded(available: Bool) {
        guard available else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !altimeterStarted else { return }
        altimeterStarted = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let meters = data?.relativeAltitude.doubleValue else { return }
            self.lock.lock()
            self.relativeAltitudeMeters = meters
            self.lock.unlock()
        }
    }

    private func currentRelativeAltitude() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return relativeAltitudeMeters
    }

    private static func mapActivity(_ activity: CMMotionActivity?) -> MotionActivityKind {
        guard let activity else { return .unknown }
        if activity.stationary { return .stationary }
        if activity.walking { return .walking }
        if activity.running { return .running }
        if activity.cycling { return .cycling }
        if activity.automotive { return .automotive }
        return .unknown
    }
}
#endif
