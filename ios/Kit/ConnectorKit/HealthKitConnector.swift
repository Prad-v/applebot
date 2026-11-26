import Foundation
import LLMKit

/// A named HealthKit metric the assistant can summarise or list.
public enum HealthMetric: String, Sendable, CaseIterable, Codable {
    case steps
    case distance
    case activeEnergy
    case heartRate
    case restingHeartRate
    case sleep
    case weight
    case bloodOxygen
    case respiratoryRate
    case bloodPressureSystolic
    case bloodPressureDiastolic

    public var displayName: String {
        switch self {
        case .steps: return "Steps"
        case .distance: return "Walking + running distance"
        case .activeEnergy: return "Active energy"
        case .heartRate: return "Heart rate"
        case .restingHeartRate: return "Resting heart rate"
        case .sleep: return "Sleep"
        case .weight: return "Weight"
        case .bloodOxygen: return "Blood oxygen"
        case .respiratoryRate: return "Respiratory rate"
        case .bloodPressureSystolic: return "Blood pressure (systolic)"
        case .bloodPressureDiastolic: return "Blood pressure (diastolic)"
        }
    }

    /// Aliases the model / user may pass as `metric`.
    public static func parse(_ raw: String) -> HealthMetric? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        switch key {
        case "steps", "step", "step_count": return .steps
        case "distance", "walking", "running", "walking_running": return .distance
        case "active_energy", "activeenergy", "calories", "energy": return .activeEnergy
        case "heart_rate", "heartrate", "hr", "pulse": return .heartRate
        case "resting_heart_rate", "resting_hr", "restingheartrate": return .restingHeartRate
        case "sleep", "sleep_analysis", "asleep": return .sleep
        case "weight", "body_mass", "bodymass": return .weight
        case "blood_oxygen", "oxygen", "spo2", "oxygen_saturation": return .bloodOxygen
        case "respiratory_rate", "breathing", "respiration": return .respiratoryRate
        case "blood_pressure_systolic", "systolic", "bp_systolic": return .bloodPressureSystolic
        case "blood_pressure_diastolic", "diastolic", "bp_diastolic": return .bloodPressureDiastolic
        default: return HealthMetric(rawValue: key)
        }
    }
}

/// One quantity / category sample from Apple Health.
public struct HealthSampleInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var metric: HealthMetric
    public var value: Double
    public var unit: String
    public var start: Date
    public var end: Date
    public var sourceName: String?

    public init(
        id: String,
        metric: HealthMetric,
        value: Double,
        unit: String,
        start: Date,
        end: Date,
        sourceName: String? = nil
    ) {
        self.id = id
        self.metric = metric
        self.value = value
        self.unit = unit
        self.start = start
        self.end = end
        self.sourceName = sourceName
    }
}

/// One workout from Apple Health.
public struct HealthWorkoutInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var activityType: String
    public var start: Date
    public var end: Date
    public var durationMinutes: Double
    public var totalEnergyKcal: Double?
    public var totalDistanceMeters: Double?

    public init(
        id: String,
        activityType: String,
        start: Date,
        end: Date,
        durationMinutes: Double,
        totalEnergyKcal: Double? = nil,
        totalDistanceMeters: Double? = nil
    ) {
        self.id = id
        self.activityType = activityType
        self.start = start
        self.end = end
        self.durationMinutes = durationMinutes
        self.totalEnergyKcal = totalEnergyKcal
        self.totalDistanceMeters = totalDistanceMeters
    }
}

/// Clinical / FHIR-style health record entry when Health Records access is available.
public struct HealthClinicalRecordInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var recordType: String
    public var displayName: String
    public var date: Date?
    public var fhirSummary: String?

    public init(
        id: String,
        recordType: String,
        displayName: String,
        date: Date? = nil,
        fhirSummary: String? = nil
    ) {
        self.id = id
        self.recordType = recordType
        self.displayName = displayName
        self.date = date
        self.fhirSummary = fhirSummary
    }
}

/// Aggregated totals / ranges for a date window.
public struct HealthSummaryInfo: Sendable, Equatable {
    public var steps: Double?
    public var distanceMeters: Double?
    public var activeEnergyKcal: Double?
    public var heartRateAvg: Double?
    public var heartRateMin: Double?
    public var heartRateMax: Double?
    public var restingHeartRate: Double?
    public var sleepHours: Double?
    public var weightKg: Double?
    public var bloodOxygenAvg: Double?
    public var workoutCount: Int
    public var sampleCount: Int

    public init(
        steps: Double? = nil,
        distanceMeters: Double? = nil,
        activeEnergyKcal: Double? = nil,
        heartRateAvg: Double? = nil,
        heartRateMin: Double? = nil,
        heartRateMax: Double? = nil,
        restingHeartRate: Double? = nil,
        sleepHours: Double? = nil,
        weightKg: Double? = nil,
        bloodOxygenAvg: Double? = nil,
        workoutCount: Int = 0,
        sampleCount: Int = 0
    ) {
        self.steps = steps
        self.distanceMeters = distanceMeters
        self.activeEnergyKcal = activeEnergyKcal
        self.heartRateAvg = heartRateAvg
        self.heartRateMin = heartRateMin
        self.heartRateMax = heartRateMax
        self.restingHeartRate = restingHeartRate
        self.sleepHours = sleepHours
        self.weightKg = weightKg
        self.bloodOxygenAvg = bloodOxygenAvg
        self.workoutCount = workoutCount
        self.sampleCount = sampleCount
    }
}

/// Source of Apple Health data. `HealthKitStoreProvider` is the real one; `InMemoryHealthKitProvider` for tests.
public protocol HealthKitProvider: Sendable {
    func permission() async -> PermissionState
    func requestAccess() async throws -> Bool
    func isAvailable() async -> Bool
    func summary(from start: Date, to end: Date) async throws -> HealthSummaryInfo
    func samples(metric: HealthMetric, from start: Date, to end: Date, limit: Int) async throws -> [HealthSampleInfo]
    func workouts(from start: Date, to end: Date, limit: Int) async throws -> [HealthWorkoutInfo]
    func clinicalRecords(recordType: String?, limit: Int) async throws -> [HealthClinicalRecordInfo]
}

public actor InMemoryHealthKitProvider: HealthKitProvider {
    private var state: PermissionState
    private var samples: [HealthSampleInfo]
    private var workouts: [HealthWorkoutInfo]
    private var records: [HealthClinicalRecordInfo]
    private let grantOnRequest: Bool
    private let available: Bool

    public init(
        permission: PermissionState = .authorized,
        samples: [HealthSampleInfo] = [],
        workouts: [HealthWorkoutInfo] = [],
        records: [HealthClinicalRecordInfo] = [],
        grantOnRequest: Bool = true,
        available: Bool = true
    ) {
        self.state = permission
        self.samples = samples
        self.workouts = workouts
        self.records = records
        self.grantOnRequest = grantOnRequest
        self.available = available
    }

    public func permission() -> PermissionState {
        if !available { return .restricted }
        return state
    }

    public func isAvailable() -> Bool { available }

    public func requestAccess() -> Bool {
        guard available else { return false }
        if state == .notDetermined { state = grantOnRequest ? .authorized : .denied }
        return state == .authorized
    }

    public func summary(from start: Date, to end: Date) throws -> HealthSummaryInfo {
        try requireAuthorized()
        let window = samples.filter { $0.start < end && $0.end > start }
        func sum(_ metric: HealthMetric) -> Double? {
            let values = window.filter { $0.metric == metric }.map(\.value)
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        func avg(_ metric: HealthMetric) -> Double? {
            let values = window.filter { $0.metric == metric }.map(\.value)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
        func extremes(_ metric: HealthMetric) -> (Double?, Double?) {
            let values = window.filter { $0.metric == metric }.map(\.value)
            return (values.min(), values.max())
        }
        let hr = extremes(.heartRate)
        let sleepSeconds = window.filter { $0.metric == .sleep }.map(\.value).reduce(0, +)
        let latestWeight = window.filter { $0.metric == .weight }.sorted { $0.end > $1.end }.first?.value
        let resting = window.filter { $0.metric == .restingHeartRate }.sorted { $0.end > $1.end }.first?.value
        let workoutHits = workouts.filter { $0.start < end && $0.end > start }
        return HealthSummaryInfo(
            steps: sum(.steps),
            distanceMeters: sum(.distance),
            activeEnergyKcal: sum(.activeEnergy),
            heartRateAvg: avg(.heartRate),
            heartRateMin: hr.0,
            heartRateMax: hr.1,
            restingHeartRate: resting,
            sleepHours: sleepSeconds > 0 ? sleepSeconds / 3600 : nil,
            weightKg: latestWeight,
            bloodOxygenAvg: avg(.bloodOxygen),
            workoutCount: workoutHits.count,
            sampleCount: window.count
        )
    }

    public func samples(metric: HealthMetric, from start: Date, to end: Date, limit: Int) throws -> [HealthSampleInfo] {
        try requireAuthorized()
        return Array(
            samples
                .filter { $0.metric == metric && $0.start < end && $0.end > start }
                .sorted { $0.start > $1.start }
                .prefix(limit)
        )
    }

    public func workouts(from start: Date, to end: Date, limit: Int) throws -> [HealthWorkoutInfo] {
        try requireAuthorized()
        return Array(
            workouts
                .filter { $0.start < end && $0.end > start }
                .sorted { $0.start > $1.start }
                .prefix(limit)
        )
    }

    public func clinicalRecords(recordType: String?, limit: Int) throws -> [HealthClinicalRecordInfo] {
        try requireAuthorized()
        var list = records
        if let recordType {
            let needle = recordType.lowercased()
            list = list.filter {
                $0.recordType.lowercased().contains(needle) || $0.displayName.lowercased().contains(needle)
            }
        }
        return Array(list.prefix(limit))
    }

    public func allSamples() -> [HealthSampleInfo] { samples }
    public func allWorkouts() -> [HealthWorkoutInfo] { workouts }
    public func allRecords() -> [HealthClinicalRecordInfo] { records }

    private func requireAuthorized() throws {
        guard available else {
            throw ConnectorError.notConfigured("Apple Health is not available on this device.")
        }
        guard state == .authorized else {
            throw ConnectorError.permissionDenied("Apple Health access has not been granted.")
        }
    }
}

/// Reads Apple Health (HealthKit) on this iPhone so the chat can answer questions about activity,
/// vitals and clinical health records. Read-only; nothing is written to Health.
public struct HealthKitConnector: Connector {
    public let id = "health"
    public let displayName = "Apple Health"
    public let summary = "See steps, sleep, heart rate, workouts and health records from Apple Health."
    public let symbolName = "heart.text.square"
    public let dataNote =
        "Reads Health data on this iPhone only. Values are given to the on-device model and never leave the device. "
        + "Applebot is not a medical device and does not give medical advice."
    public let hasAccount = false

    /// Shared with the Health tab dashboard (read-only).
    public let provider: HealthKitProvider
    private let calendar: Calendar
    private let clock: @Sendable () -> Date

    public static let maxDays = 30
    public static let maxSamples = 40
    public static let maxWorkouts = 20
    public static let maxRecords = 25

    public init(
        provider: HealthKitProvider,
        calendar: Calendar = .current,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.calendar = calendar
        self.clock = clock
    }

    public func status() async -> ConnectorStatus {
        guard await provider.isAvailable() else {
            return .unavailable("Apple Health is not available on this device.")
        }
        switch await provider.permission() {
        case .authorized: return .connected(account: nil)
        case .notDetermined: return .notConnected
        case .denied: return .unavailable("Apple Health access was denied. Allow it in Settings > Applebot > Health.")
        case .restricted: return .unavailable("Apple Health access is restricted on this device.")
        }
    }

    public func connect() async throws {
        guard await provider.isAvailable() else {
            throw ConnectorError.notConfigured("Apple Health is not available on this device.")
        }
        let granted = try await provider.requestAccess()
        guard granted else {
            throw ConnectorError.permissionDenied(
                "Apple Health access was not granted. Allow categories in Settings > Applebot > Health."
            )
        }
    }

    public func disconnect() async {}

    public func tools() -> [ToolSpec] {
        [summaryTool, listSamplesTool, listWorkoutsTool, listRecordsTool]
    }

    // MARK: Tools

    private var summaryTool: ToolSpec {
        let provider = self.provider, calendar = self.calendar, clock = self.clock
        return ToolSpec(
            name: "health_summary",
            description:
                "Summarise the user's Apple Health activity and vitals for a date range "
                + "(steps, distance, active energy, heart rate, sleep, weight, workouts). "
                + "Use for questions like how many steps today, how I slept, or a weekly health overview. "
                + "Not medical advice.",
            parameters: [
                ToolParameter("start_date", "First day as YYYY-MM-DD (or 'today' / 'tomorrow'). Defaults to today.", required: false),
                ToolParameter("days", "How many days to include, 1 to \(Self.maxDays). Defaults to 1.", kind: .integer, required: false),
            ],
            label: "Checking Apple Health",
            handler: { arguments in
                let (first, days, end) = try Self.range(from: arguments, now: clock(), calendar: calendar)
                let summary = try await provider.summary(from: first, to: end)
                let range = DateInput.format(first, calendar: calendar, includeTime: false)
                return Self.describeSummary(summary, rangeLabel: range, days: days)
            }
        )
    }

    private var listSamplesTool: ToolSpec {
        let provider = self.provider, calendar = self.calendar, clock = self.clock
        return ToolSpec(
            name: "health_list_samples",
            description:
                "List individual Apple Health samples for one metric "
                + "(steps, distance, active_energy, heart_rate, resting_heart_rate, sleep, weight, "
                + "blood_oxygen, respiratory_rate, blood_pressure_systolic, blood_pressure_diastolic). "
                + "Use when the user wants detail beyond a summary.",
            parameters: [
                ToolParameter("metric", "Which metric to list."),
                ToolParameter("start_date", "First day as YYYY-MM-DD (or 'today'). Defaults to today.", required: false),
                ToolParameter("days", "How many days to include, 1 to \(Self.maxDays). Defaults to 1.", kind: .integer, required: false),
                ToolParameter("limit", "Max samples to return, 1 to \(Self.maxSamples). Defaults to 15.", kind: .integer, required: false),
            ],
            label: "Reading Health samples",
            handler: { arguments in
                guard let raw = arguments.string("metric"), let metric = HealthMetric.parse(raw) else {
                    throw ConnectorError.invalidArgument(
                        "metric must be one of: steps, distance, active_energy, heart_rate, resting_heart_rate, "
                            + "sleep, weight, blood_oxygen, respiratory_rate, blood_pressure_systolic, blood_pressure_diastolic."
                    )
                }
                let (first, days, end) = try Self.range(from: arguments, now: clock(), calendar: calendar)
                let limit = min(max(arguments.integer("limit") ?? 15, 1), Self.maxSamples)
                let items = try await provider.samples(metric: metric, from: first, to: end, limit: limit)
                let range = DateInput.format(first, calendar: calendar, includeTime: false)
                guard !items.isEmpty else {
                    return "No \(metric.displayName.lowercased()) samples for \(range)"
                        + (days > 1 ? " and the next \(days - 1) day(s)." : ".")
                }
                let lines = items.map { Self.describeSample($0, calendar: calendar) }
                return "\(metric.displayName) from \(range) for \(days) day(s):\n" + lines.joined(separator: "\n")
            }
        )
    }

    private var listWorkoutsTool: ToolSpec {
        let provider = self.provider, calendar = self.calendar, clock = self.clock
        return ToolSpec(
            name: "health_list_workouts",
            description: "List workouts recorded in Apple Health for a date range.",
            parameters: [
                ToolParameter("start_date", "First day as YYYY-MM-DD (or 'today'). Defaults to today.", required: false),
                ToolParameter("days", "How many days to include, 1 to \(Self.maxDays). Defaults to 7.", kind: .integer, required: false),
                ToolParameter("limit", "Max workouts, 1 to \(Self.maxWorkouts). Defaults to 10.", kind: .integer, required: false),
            ],
            label: "Checking workouts",
            handler: { arguments in
                let now = clock()
                var first = calendar.startOfDay(for: now)
                let defaultDays = 7
                if let raw = arguments.string("start_date") {
                    guard let parsed = DateInput.parse(raw, now: now, calendar: calendar) else {
                        throw ConnectorError.invalidArgument("start_date must look like 2026-11-21.")
                    }
                    first = calendar.startOfDay(for: parsed.date)
                } else if arguments.integer("days") == nil {
                    // Default window: last 7 days through end of today.
                    first = calendar.date(byAdding: .day, value: -(defaultDays - 1), to: first) ?? first
                }
                let days = min(
                    max(arguments.integer("days") ?? (arguments.string("start_date") == nil ? defaultDays : 1), 1),
                    Self.maxDays
                )
                guard let end = calendar.date(byAdding: .day, value: days, to: first) else {
                    throw ConnectorError.invalidArgument("Could not work out the date range.")
                }
                let limit = min(max(arguments.integer("limit") ?? 10, 1), Self.maxWorkouts)
                let items = try await provider.workouts(from: first, to: end, limit: limit)
                let range = DateInput.format(first, calendar: calendar, includeTime: false)
                guard !items.isEmpty else {
                    return "No workouts for \(range)\(days > 1 ? " and the next \(days - 1) day(s)" : "")."
                }
                let lines = items.map { Self.describeWorkout($0, calendar: calendar) }
                return "Workouts from \(range) for \(days) day(s):\n" + lines.joined(separator: "\n")
            }
        )
    }

    private var listRecordsTool: ToolSpec {
        let provider = self.provider
        return ToolSpec(
            name: "health_list_records",
            description:
                "List clinical health records imported into Apple Health "
                + "(allergies, conditions, immunizations, lab results, medications, procedures, vital signs). "
                + "Use when the user asks about health records, medications, allergies or lab results from their providers. "
                + "May be empty if Health Records are not linked or not authorised.",
            parameters: [
                ToolParameter(
                    "record_type",
                    "Optional filter: allergy, condition, immunization, lab, medication, procedure, or vital.",
                    required: false
                ),
                ToolParameter("limit", "Max records, 1 to \(Self.maxRecords). Defaults to 15.", kind: .integer, required: false),
            ],
            label: "Reading health records",
            handler: { arguments in
                let limit = min(max(arguments.integer("limit") ?? 15, 1), Self.maxRecords)
                let type = arguments.string("record_type")
                let items = try await provider.clinicalRecords(recordType: type, limit: limit)
                guard !items.isEmpty else {
                    if let type {
                        return "No clinical health records matched “\(type)”. "
                            + "Link a healthcare provider in the Health app (Browse → Health Records), "
                            + "allow that category for Applebot, and try again."
                    }
                    return "No clinical health records are available. "
                        + "Download records from a supported provider in the Health app "
                        + "(Browse → Health Records), then allow those categories for Applebot in "
                        + "Settings → Health. Applebot is not a medical device and does not give medical advice."
                }
                let lines = items.map(Self.describeRecord)
                return "Clinical health records:\n" + lines.joined(separator: "\n")
            }
        )
    }

    // MARK: Helpers

    static func range(
        from arguments: ToolArguments,
        now: Date,
        calendar: Calendar
    ) throws -> (start: Date, days: Int, end: Date) {
        var first = calendar.startOfDay(for: now)
        if let raw = arguments.string("start_date") {
            guard let parsed = DateInput.parse(raw, now: now, calendar: calendar) else {
                throw ConnectorError.invalidArgument("start_date must look like 2026-11-21.")
            }
            first = calendar.startOfDay(for: parsed.date)
        }
        let days = min(max(arguments.integer("days") ?? 1, 1), maxDays)
        guard let end = calendar.date(byAdding: .day, value: days, to: first) else {
            throw ConnectorError.invalidArgument("Could not work out the date range.")
        }
        return (first, days, end)
    }

    static func describeSummary(_ summary: HealthSummaryInfo, rangeLabel: String, days: Int) -> String {
        var lines: [String] = [
            "Apple Health summary for \(rangeLabel)"
                + (days > 1 ? " and the next \(days - 1) day(s)" : "") + ":"
        ]
        if let steps = summary.steps {
            lines.append("- Steps: \(Self.formatNumber(steps, fractionDigits: 0))")
        }
        if let distance = summary.distanceMeters {
            let km = distance / 1000
            lines.append("- Distance: \(Self.formatNumber(km, fractionDigits: 2)) km")
        }
        if let energy = summary.activeEnergyKcal {
            lines.append("- Active energy: \(Self.formatNumber(energy, fractionDigits: 0)) kcal")
        }
        if let avg = summary.heartRateAvg {
            var hr = "- Heart rate: avg \(Self.formatNumber(avg, fractionDigits: 0)) bpm"
            if let lo = summary.heartRateMin, let hi = summary.heartRateMax {
                hr += " (range \(Self.formatNumber(lo, fractionDigits: 0))–\(Self.formatNumber(hi, fractionDigits: 0)))"
            }
            lines.append(hr)
        }
        if let resting = summary.restingHeartRate {
            lines.append("- Resting heart rate: \(Self.formatNumber(resting, fractionDigits: 0)) bpm")
        }
        if let sleep = summary.sleepHours {
            lines.append("- Sleep: \(Self.formatNumber(sleep, fractionDigits: 1)) hours")
        }
        if let weight = summary.weightKg {
            lines.append("- Weight: \(Self.formatNumber(weight, fractionDigits: 1)) kg")
        }
        if let spo2 = summary.bloodOxygenAvg {
            lines.append("- Blood oxygen (avg): \(Self.formatNumber(spo2 * 100, fractionDigits: 0))%")
        }
        lines.append("- Workouts: \(summary.workoutCount)")
        if lines.count == 2 && summary.sampleCount == 0 && summary.workoutCount == 0 {
            return "No Apple Health data for \(rangeLabel)"
                + (days > 1 ? " and the next \(days - 1) day(s)." : ".")
        }
        lines.append("Note: informational only — not medical advice.")
        return lines.joined(separator: "\n")
    }

    static func describeSample(_ sample: HealthSampleInfo, calendar: Calendar) -> String {
        let when = DateInput.format(sample.start, calendar: calendar)
        var valueText: String
        switch sample.metric {
        case .sleep:
            valueText = "\(formatNumber(sample.value / 3600, fractionDigits: 2)) h"
        case .distance:
            valueText = "\(formatNumber(sample.value / 1000, fractionDigits: 2)) km"
        case .bloodOxygen:
            valueText = "\(formatNumber(sample.value * 100, fractionDigits: 0))%"
        case .steps, .activeEnergy, .heartRate, .restingHeartRate,
             .respiratoryRate, .bloodPressureSystolic, .bloodPressureDiastolic:
            valueText = "\(formatNumber(sample.value, fractionDigits: 0)) \(sample.unit)"
        case .weight:
            valueText = "\(formatNumber(sample.value, fractionDigits: 1)) \(sample.unit)"
        }
        var line = "- \(when) | \(valueText)"
        if let source = sample.sourceName, !source.isEmpty { line += " | \(source)" }
        return line
    }

    static func describeWorkout(_ workout: HealthWorkoutInfo, calendar: Calendar) -> String {
        var line = "- \(DateInput.format(workout.start, calendar: calendar)) | \(workout.activityType) | "
            + "\(formatNumber(workout.durationMinutes, fractionDigits: 0)) min"
        if let kcal = workout.totalEnergyKcal {
            line += " | \(formatNumber(kcal, fractionDigits: 0)) kcal"
        }
        if let meters = workout.totalDistanceMeters {
            line += " | \(formatNumber(meters / 1000, fractionDigits: 2)) km"
        }
        return line
    }

    static func describeRecord(_ record: HealthClinicalRecordInfo) -> String {
        var line = "- [\(record.recordType)] \(record.displayName)"
        if let date = record.date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            line += " | \(formatter.string(from: date))"
        }
        if let summary = record.fhirSummary, !summary.isEmpty {
            line += " | \(summary.prefix(160))"
        }
        return line
    }

    static func formatNumber(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
