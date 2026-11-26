import XCTest
import LLMKit
@testable import ConnectorKit

private func tool(_ name: String, in connector: some Connector) throws -> ToolSpec {
    try XCTUnwrap(connector.tools().first { $0.name == name })
}

final class SensorCapabilityTests: XCTestCase {
    func testMotionWarningsWhenPedometerMissing() {
        let caps = MotionCapabilities(
            deviceMotion: true, pedometer: false, activity: false, relativeAltitude: true
        )
        XCTAssertFalse(caps.sedentarySupported)
        let warnings = caps.warnings
        XCTAssertTrue(warnings.contains(where: { $0.contains("Sedentary") }))
        XCTAssertTrue(warnings.contains(where: { $0.contains("Step counting") }))
        XCTAssertFalse(SensorCapability.disabledIDs(from: caps.features).contains("device-motion"))
        XCTAssertTrue(SensorCapability.disabledIDs(from: caps.features).contains("sedentary"))
    }

    func testTrailARAirDisablesOnlyLiDAR() {
        let caps = TrailARCapabilities.airNoLidar
        XCTAssertTrue(caps.compassOverlaySupported)
        XCTAssertFalse(caps.depthMeshSupported)
        let warnings = caps.warnings
        XCTAssertTrue(warnings.contains(where: { $0.contains("LiDAR") }))
        XCTAssertFalse(warnings.contains(where: { $0.contains("AR trail overlay:") && $0.contains("unavailable") }))
        // World tracking feature itself should be available — no warning line for it.
        XCTAssertNil(caps.features.first(where: { $0.id == "ar-world-tracking" })?.warningLine)
    }

    func testTrailARNoneDisablesOverlay() {
        let caps = TrailARCapabilities.none
        XCTAssertFalse(caps.compassOverlaySupported)
        XCTAssertNotNil(caps.features.first(where: { $0.id == "ar-world-tracking" })?.warningLine)
    }

    func testSurroundingsAirKeepsDescribeWithoutLiDAR() {
        let caps = SurroundingsCapabilities.airTypical
        XCTAssertTrue(caps.describeSupported)
        XCTAssertFalse(caps.lidarDepthAssist)
        XCTAssertTrue(caps.warnings.contains(where: { $0.contains("LiDAR") }))
        XCTAssertNil(caps.features.first(where: { $0.id == "surroundings-describe" })?.warningLine)
    }

    func testRoomScanAirDisablesScan() {
        let caps = RoomScanCapabilities.airTypical
        XCTAssertFalse(caps.scanSupported)
        XCTAssertTrue(caps.warnings.contains(where: { $0.contains("RoomPlan") || $0.contains("LiDAR") }))
        XCTAssertTrue(RoomScanCapabilities.proTypical.scanSupported)
    }
}

final class MotionConnectorTests: XCTestCase {
    func testSedentaryToolWhenAuthorized() async throws {
        let provider = InMemoryMotionProvider(
            permission: .authorized,
            capabilities: .allAvailable,
            snapshot: MotionSedentarySnapshot(
                activity: .stationary,
                stepsLastTwoHours: 40,
                stepsToday: 900,
                floorsAscended: 1,
                sedentaryLikely: true,
                note: "Few steps in the last two hours while stationary.",
                capabilities: .allAvailable
            )
        )
        let connector = MotionConnector(provider: provider)
        XCTAssertEqual(connector.id, "motion")
        XCTAssertFalse(connector.usesNetwork)
        let status = await connector.status()
        XCTAssertEqual(status, .connected(account: nil))

        let output = try await tool("motion_sedentary", in: connector).handler(ToolArguments([:]))
        XCTAssertTrue(output.contains("Stationary"))
        XCTAssertTrue(output.contains("40"))
        XCTAssertTrue(output.lowercased().contains("sedentary likely: yes"))
    }

    func testUnavailableWhenNoPedometerOrActivity() async throws {
        let provider = InMemoryMotionProvider(
            permission: .authorized,
            capabilities: MotionCapabilities(deviceMotion: true, pedometer: false, activity: false)
        )
        let connector = MotionConnector(provider: provider)
        let status = await connector.status()
        guard case .unavailable(let message) = status else {
            return XCTFail("expected unavailable, got \(status)")
        }
        XCTAssertTrue(message.lowercased().contains("sedentary") || message.lowercased().contains("step"))

        await assertFails {
            _ = try await tool("motion_sedentary", in: connector).handler(ToolArguments([:]))
        }
    }

    func testCapabilitiesToolListsDisabledSensors() async throws {
        let caps = MotionCapabilities(
            deviceMotion: true, pedometer: true, activity: false, relativeAltitude: false
        )
        let provider = InMemoryMotionProvider(permission: .authorized, capabilities: caps)
        let connector = MotionConnector(provider: provider)
        let output = try await tool("motion_capabilities", in: connector).handler(ToolArguments([:]))
        XCTAssertTrue(output.contains("Step counting: available"))
        XCTAssertTrue(output.contains("Motion activity: disabled"))
        XCTAssertTrue(output.contains("Barometer altitude: disabled"))
    }

    func testEvaluateSedentaryHeuristic() {
        let caps = MotionCapabilities.allAvailable
        let sitting = MotionConnector.evaluateSedentary(
            activity: .stationary, stepsLastTwoHours: 50, capabilities: caps
        )
        XCTAssertTrue(sitting.likely)

        let walking = MotionConnector.evaluateSedentary(
            activity: .walking, stepsLastTwoHours: 50, capabilities: caps
        )
        XCTAssertFalse(walking.likely)

        let none = MotionConnector.evaluateSedentary(
            activity: .stationary, stepsLastTwoHours: 50, capabilities: .none
        )
        XCTAssertFalse(none.likely)
    }

    func testConnectDenied() async {
        let provider = InMemoryMotionProvider(permission: .notDetermined, grantOnRequest: false)
        let connector = MotionConnector(provider: provider)
        do {
            try await connector.connect()
            XCTFail("expected denial")
        } catch let error as ConnectorError {
            guard case .permissionDenied = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func assertFails(_ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected throw")
        } catch let error as ConnectorError {
            guard case .notConfigured = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
