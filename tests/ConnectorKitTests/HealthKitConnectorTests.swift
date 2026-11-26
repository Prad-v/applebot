import XCTest
import LLMKit
@testable import ConnectorKit

final class HealthKitConnectorTests: XCTestCase {
    private let calendar = utcCalendar()
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T10:30:00Z")!

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func connector(
        permission: PermissionState = .authorized,
        samples: [HealthSampleInfo] = [],
        workouts: [HealthWorkoutInfo] = [],
        records: [HealthClinicalRecordInfo] = [],
        available: Bool = true
    ) -> (HealthKitConnector, InMemoryHealthKitProvider) {
        let provider = InMemoryHealthKitProvider(
            permission: permission,
            samples: samples,
            workouts: workouts,
            records: records,
            available: available
        )
        let now = self.now
        return (HealthKitConnector(provider: provider, calendar: calendar, clock: { now }), provider)
    }

    private func tool(_ name: String, in connector: HealthKitConnector) throws -> ToolSpec {
        try XCTUnwrap(connector.tools().first { $0.name == name })
    }

    private var sampleDay: [HealthSampleInfo] {
        [
            HealthSampleInfo(
                id: "1", metric: .steps, value: 4200, unit: "steps",
                start: at("2026-11-18T08:00:00Z"), end: at("2026-11-18T09:00:00Z")
            ),
            HealthSampleInfo(
                id: "2", metric: .steps, value: 1800, unit: "steps",
                start: at("2026-11-18T12:00:00Z"), end: at("2026-11-18T13:00:00Z")
            ),
            HealthSampleInfo(
                id: "3", metric: .heartRate, value: 72, unit: "bpm",
                start: at("2026-11-18T09:00:00Z"), end: at("2026-11-18T09:00:00Z")
            ),
            HealthSampleInfo(
                id: "4", metric: .heartRate, value: 110, unit: "bpm",
                start: at("2026-11-18T09:30:00Z"), end: at("2026-11-18T09:30:00Z")
            ),
            HealthSampleInfo(
                id: "5", metric: .sleep, value: 7.5 * 3600, unit: "s",
                start: at("2026-11-17T23:00:00Z"), end: at("2026-11-18T06:30:00Z")
            ),
            HealthSampleInfo(
                id: "6", metric: .activeEnergy, value: 450, unit: "kcal",
                start: at("2026-11-18T08:00:00Z"), end: at("2026-11-18T18:00:00Z")
            ),
            HealthSampleInfo(
                id: "7", metric: .steps, value: 9000, unit: "steps",
                start: at("2026-11-19T08:00:00Z"), end: at("2026-11-19T09:00:00Z")
            ),
        ]
    }

    private var sampleWorkouts: [HealthWorkoutInfo] {
        [
            HealthWorkoutInfo(
                id: "w1", activityType: "Running",
                start: at("2026-11-18T07:00:00Z"), end: at("2026-11-18T07:40:00Z"),
                durationMinutes: 40, totalEnergyKcal: 380, totalDistanceMeters: 6500
            ),
            HealthWorkoutInfo(
                id: "w2", activityType: "Yoga",
                start: at("2026-11-16T08:00:00Z"), end: at("2026-11-16T08:45:00Z"),
                durationMinutes: 45
            ),
        ]
    }

    private var sampleRecords: [HealthClinicalRecordInfo] {
        [
            HealthClinicalRecordInfo(id: "r1", recordType: "allergy", displayName: "Penicillin"),
            HealthClinicalRecordInfo(
                id: "r2", recordType: "medication", displayName: "Lisinopril 10mg",
                date: at("2026-01-15T00:00:00Z"), fhirSummary: "Take once daily"
            ),
            HealthClinicalRecordInfo(id: "r3", recordType: "condition", displayName: "Seasonal allergies"),
        ]
    }

    // MARK: Status

    func testStatusFollowsPermissionAndAvailability() async {
        let cases: [(PermissionState, Bool)] = [
            (.authorized, true), (.notDetermined, false), (.denied, false), (.restricted, false),
        ]
        for (permission, connected) in cases {
            let (health, _) = connector(permission: permission)
            let status = await health.status()
            XCTAssertEqual(status.isConnected, connected, "\(permission)")
        }

        let (denied, _) = connector(permission: .denied)
        guard case .unavailable(let why) = await denied.status() else {
            return XCTFail("denied should be unavailable")
        }
        XCTAssertTrue(why.contains("Settings"))

        let (missing, _) = connector(available: false)
        guard case .unavailable(let msg) = await missing.status() else {
            return XCTFail("unavailable device should report unavailable")
        }
        XCTAssertTrue(msg.contains("not available"))
    }

    func testConnectRequestsAccess() async throws {
        let (health, _) = connector(permission: .notDetermined)
        try await health.connect()
        let connected = await health.status().isConnected
        XCTAssertTrue(connected)
    }

    func testConnectThrowsWhenUserDenies() async {
        let provider = InMemoryHealthKitProvider(permission: .notDetermined, grantOnRequest: false)
        let health = HealthKitConnector(provider: provider, calendar: calendar)
        do {
            try await health.connect()
            XCTFail("expected permissionDenied")
        } catch let error as ConnectorError {
            guard case .permissionDenied = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Summary

    func testSummaryAggregatesToday() async throws {
        let (health, _) = connector(samples: sampleDay, workouts: sampleWorkouts)
        let output = try await tool("health_summary", in: health).handler(ToolArguments())
        XCTAssertTrue(output.contains("Steps: 6000"))
        XCTAssertTrue(output.contains("Active energy: 450 kcal"))
        XCTAssertTrue(output.contains("Heart rate"))
        XCTAssertTrue(output.contains("Sleep: 7.5 hours"))
        XCTAssertTrue(output.contains("Workouts: 1"))
        XCTAssertTrue(output.contains("not medical advice"))
        XCTAssertFalse(output.contains("9000"), "next-day steps must not appear in a 1-day summary")
    }

    func testSummaryReportsEmptyRange() async throws {
        let (health, _) = connector(samples: sampleDay)
        let output = try await tool("health_summary", in: health)
            .handler(ToolArguments(["start_date": "2026-12-25"]))
        XCTAssertTrue(output.hasPrefix("No Apple Health data"))
    }

    func testSummaryClampsDaysAndRejectsBadDate() async throws {
        let (health, _) = connector(samples: sampleDay)
        let spec = try tool("health_summary", in: health)
        let output = try await spec.handler(ToolArguments(["days": "9999"]))
        XCTAssertTrue(output.contains("next 29 day"), "days should clamp to maxDays=30; got: \(output)")
        do {
            _ = try await spec.handler(ToolArguments(["start_date": "someday"]))
            XCTFail("expected invalidArgument")
        } catch let error as ConnectorError {
            guard case .invalidArgument = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: Samples

    func testListSamplesFiltersMetricAndRange() async throws {
        let (health, _) = connector(samples: sampleDay)
        let output = try await tool("health_list_samples", in: health)
            .handler(ToolArguments(["metric": "heart_rate"]))
        XCTAssertTrue(output.contains("72 bpm"))
        XCTAssertTrue(output.contains("110 bpm"))
        XCTAssertFalse(output.contains("steps"))
    }

    func testListSamplesRejectsUnknownMetric() async throws {
        let (health, _) = connector(samples: sampleDay)
        do {
            _ = try await tool("health_list_samples", in: health)
                .handler(ToolArguments(["metric": "mood"]))
            XCTFail("expected invalidArgument")
        } catch let error as ConnectorError {
            guard case .invalidArgument = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testMetricAliasesParse() {
        XCTAssertEqual(HealthMetric.parse("step count"), .steps)
        XCTAssertEqual(HealthMetric.parse("HR"), .heartRate)
        XCTAssertEqual(HealthMetric.parse("spo2"), .bloodOxygen)
        XCTAssertEqual(HealthMetric.parse("calories"), .activeEnergy)
        XCTAssertNil(HealthMetric.parse("mood"))
    }

    func testReadingWithoutPermissionFails() async throws {
        let (health, _) = connector(permission: .denied, samples: sampleDay)
        do {
            _ = try await tool("health_summary", in: health).handler(ToolArguments())
            XCTFail("expected permissionDenied")
        } catch let error as ConnectorError {
            guard case .permissionDenied = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: Workouts

    func testListWorkoutsDefaultsToWeek() async throws {
        let (health, _) = connector(workouts: sampleWorkouts)
        let output = try await tool("health_list_workouts", in: health).handler(ToolArguments())
        XCTAssertTrue(output.contains("Running"))
        XCTAssertTrue(output.contains("40 min"))
        XCTAssertTrue(output.contains("Yoga"))
    }

    func testListWorkoutsEmptyRange() async throws {
        let (health, _) = connector(workouts: sampleWorkouts)
        let output = try await tool("health_list_workouts", in: health)
            .handler(ToolArguments(["start_date": "2026-12-01", "days": "1"]))
        XCTAssertTrue(output.hasPrefix("No workouts"))
    }

    // MARK: Clinical records

    func testListRecordsAndFilter() async throws {
        let (health, _) = connector(records: sampleRecords)
        let all = try await tool("health_list_records", in: health).handler(ToolArguments())
        XCTAssertTrue(all.contains("Penicillin"))
        XCTAssertTrue(all.contains("Lisinopril"))

        let allergies = try await tool("health_list_records", in: health)
            .handler(ToolArguments(["record_type": "allergy"]))
        XCTAssertTrue(allergies.contains("Penicillin"))
        XCTAssertFalse(allergies.contains("Lisinopril"))
    }

    func testListRecordsEmptyMessage() async throws {
        let (health, _) = connector(records: [])
        let output = try await tool("health_list_records", in: health).handler(ToolArguments())
        XCTAssertTrue(output.contains("No clinical health records"))
    }

    // MARK: Tools are read-only

    func testAllHealthToolsAreReadOnly() throws {
        let (health, _) = connector()
        for tool in health.tools() {
            XCTAssertFalse(tool.requiresApproval, tool.name)
            XCTAssertTrue(tool.name.hasPrefix("health_"), tool.name)
        }
        XCTAssertEqual(Set(health.tools().map(\.name)), [
            "health_summary", "health_list_samples", "health_list_workouts", "health_list_records",
        ])
    }
}
