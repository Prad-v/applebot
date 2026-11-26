import Foundation
import CoreLocation
import ConnectorKit

/// Live GPS via Core Location (When-In-Use only). Main-actor bound; expose `asProvider` to connectors.
@MainActor
final class CoreLocationController: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var permissionWaiters: [CheckedContinuation<Bool, Never>] = []
    private var fixWaiters: [CheckedContinuation<LocationFix, Error>] = []
    private var lastFix: LocationFix?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .fitness
    }

    var asProvider: any LocationProvider { Bridged(controller: self) }

    func permission() -> PermissionState {
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    func requestAccess() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                permissionWaiters.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        @unknown default:
            return false
        }
    }

    func currentFix() async throws -> LocationFix {
        guard permission() == .authorized else {
            throw ConnectorError.permissionDenied(
                "Location access has not been granted. Connect Location in You → Connectors."
            )
        }
        if let lastFix, Date().timeIntervalSince(lastFix.timestamp) < 15 {
            return lastFix
        }
        return try await withCheckedThrowingContinuation { continuation in
            fixWaiters.append(continuation)
            manager.requestLocation()
        }
    }

    /// Start continuous updates for the Trail tab breadcrumb recorder.
    func startUpdating() {
        guard permission() == .authorized else { return }
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    // MARK: Delegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let granted = permission() == .authorized
            let waiters = permissionWaiters
            permissionWaiters = []
            for waiter in waiters { waiter.resume(returning: granted) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let fix = LocationFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
                horizontalAccuracyMeters: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                courseDegrees: location.course >= 0 ? location.course : nil,
                speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
                timestamp: location.timestamp
            )
            lastFix = fix
            let waiters = fixWaiters
            fixWaiters = []
            for waiter in waiters { waiter.resume(returning: fix) }
            NotificationCenter.default.post(name: Self.didUpdateFix, object: fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let waiters = fixWaiters
            fixWaiters = []
            let wrapped = ConnectorError.unexpectedResponse(
                "Couldn't get a GPS fix. Move outdoors with a clear view of the sky and try again."
            )
            for waiter in waiters { waiter.resume(throwing: wrapped) }
        }
    }

    static let didUpdateFix = Notification.Name("applebot.location.didUpdateFix")

    /// Sendable bridge so `LocationConnector` can hold the provider without MainActor isolation issues.
    struct Bridged: LocationProvider, @unchecked Sendable {
        let controller: CoreLocationController

        func permission() async -> PermissionState {
            await MainActor.run { controller.permission() }
        }

        func requestAccess() async throws -> Bool {
            await controller.requestAccess()
        }

        func currentFix() async throws -> LocationFix {
            try await controller.currentFix()
        }
    }
}
