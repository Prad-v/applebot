#if canImport(HealthKit)
import Foundation
import HealthKit

/// `HealthKitProvider` backed by `HKHealthStore` on Apple platforms.
///
/// Requires `NSHealthShareUsageDescription` in Info.plist and the HealthKit entitlement.
/// Clinical records also need `NSHealthClinicalHealthRecordsShareUsageDescription` and the
/// `health-records` entitlement value. Authorization runs in two steps on the main actor so a
/// clinical failure cannot undo activity/vitals access.
public final class HealthKitStoreProvider: HealthKitProvider, @unchecked Sendable {
    private let store = HKHealthStore()

    public init() {}

    public func isAvailable() async -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public func permission() async -> PermissionState {
        guard HKHealthStore.isHealthDataAvailable() else { return .restricted }
        do {
            // Status checks use standard types only. Clinical types are requested separately
            // after Connect; mixing them into this probe is unnecessary for the Settings row.
            let status = try await store.statusForAuthorizationRequest(
                toShare: Set<HKSampleType>(),
                read: Self.standardReadTypes
            )
            switch status {
            case .shouldRequest: return .notDetermined
            case .unnecessary: return .authorized
            case .unknown: return .notDetermined
            @unknown default: return .notDetermined
            }
        } catch {
            return .notDetermined
        }
    }

    public func requestAccess() async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        // HealthKit presents system permission sheets; must run on the main actor.
        // ConnectorRegistry is a background actor, so hop explicitly.
        try await Self.requestStandardAccess(store: store)
        // Second sheet (clinical) is optional. Never throw after standard access succeeded —
        // missing entitlement / usage string / user denial must not fail Connect.
        await Self.requestClinicalAccessIfConfigured(store: store)
        // HealthKit does not reveal whether each read type was granted; completion means the
        // sheet was shown (or was unnecessary). Empty query results are the privacy model.
        return true
    }

    @MainActor
    private static func requestStandardAccess(store: HKHealthStore) async throws {
        try await store.requestAuthorization(toShare: Set<HKSampleType>(), read: standardReadTypes)
    }

    @MainActor
    private static func requestClinicalAccessIfConfigured(store: HKHealthStore) async {
        guard clinicalAuthorizationConfigured else { return }
        let clinical = Set(allClinicalTypes.map { $0 as HKObjectType })
        guard !clinical.isEmpty else { return }
        do {
            try await store.requestAuthorization(toShare: Set<HKSampleType>(), read: clinical)
        } catch {
            // Standard Health already granted; clinical stays unavailable for this session.
        }
    }

    /// Both the clinical usage string and Health Records entitlement must be present.
    /// Requesting `HKClinicalType` without either terminates the process (ObjC exception).
    private static var clinicalAuthorizationConfigured: Bool {
        guard let usage = Bundle.main.object(
            forInfoDictionaryKey: "NSHealthClinicalHealthRecordsShareUsageDescription"
        ) as? String,
        !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return Bundle.main.hasHealthRecordsEntitlement
    }

    public func summary(from start: Date, to end: Date) async throws -> HealthSummaryInfo {
        try await requireReady()
        async let steps = sum(.steps, from: start, to: end)
        async let distance = sum(.distance, from: start, to: end)
        async let energy = sum(.activeEnergy, from: start, to: end)
        async let hrStats = statistics(.heartRate, from: start, to: end)
        async let resting = latest(.restingHeartRate, from: start, to: end)
        async let sleepSeconds = sleepDuration(from: start, to: end)
        async let weight = latest(.weight, from: start, to: end)
        async let spo2 = average(.bloodOxygen, from: start, to: end)
        async let workoutList = workouts(from: start, to: end, limit: HealthKitConnector.maxWorkouts)

        let hr = await hrStats
        let slept = await sleepSeconds
        return HealthSummaryInfo(
            steps: await steps,
            distanceMeters: await distance,
            activeEnergyKcal: await energy,
            heartRateAvg: hr?.average,
            heartRateMin: hr?.minimum,
            heartRateMax: hr?.maximum,
            restingHeartRate: await resting,
            sleepHours: slept > 0 ? slept / 3600 : nil,
            weightKg: await weight,
            bloodOxygenAvg: await spo2,
            workoutCount: try await workoutList.count,
            sampleCount: 0
        )
    }

    public func samples(
        metric: HealthMetric,
        from start: Date,
        to end: Date,
        limit: Int
    ) async throws -> [HealthSampleInfo] {
        try await requireReady()
        if metric == .sleep {
            return try await sleepSamples(from: start, to: end, limit: limit)
        }
        guard let quantityType = Self.quantityType(for: metric) else {
            throw ConnectorError.invalidArgument("Unsupported metric for samples.")
        }
        let unit = Self.unit(for: metric)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
        return samples.map { sample in
            HealthSampleInfo(
                id: sample.uuid.uuidString,
                metric: metric,
                value: sample.quantity.doubleValue(for: unit),
                unit: Self.unitLabel(for: metric),
                start: sample.startDate,
                end: sample.endDate,
                sourceName: sample.sourceRevision.source.name
            )
        }
    }

    public func workouts(from start: Date, to end: Date, limit: Int) async throws -> [HealthWorkoutInfo] {
        try await requireReady()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        return samples.map { workout in
            let energy = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            let distance = workout.totalDistance?.doubleValue(for: .meter())
            return HealthWorkoutInfo(
                id: workout.uuid.uuidString,
                activityType: Self.workoutName(workout.workoutActivityType),
                start: workout.startDate,
                end: workout.endDate,
                durationMinutes: workout.duration / 60,
                totalEnergyKcal: energy,
                totalDistanceMeters: distance
            )
        }
    }

    public func clinicalRecords(recordType: String?, limit: Int) async throws -> [HealthClinicalRecordInfo] {
        try await requireReady()
        let types = Self.clinicalTypes(matching: recordType)
        guard !types.isEmpty else { return [] }

        var collected: [HealthClinicalRecordInfo] = []
        for type in types {
            guard collected.count < limit else { break }
            let remaining = limit - collected.count
            let batch: [HKClinicalRecord]
            do {
                batch = try await queryClinical(type: type, limit: remaining)
            } catch {
                // Missing Health Records entitlement or denied type → skip quietly.
                continue
            }
            for record in batch {
                collected.append(HealthClinicalRecordInfo(
                    id: record.uuid.uuidString,
                    recordType: Self.clinicalTypeLabel(type),
                    displayName: record.displayName,
                    date: record.startDate,
                    fhirSummary: Self.fhirBrief(record)
                ))
            }
        }
        return collected
    }

    // MARK: Private queries

    private func requireReady() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw ConnectorError.notConfigured("Apple Health is not available on this device.")
        }
        guard await permission() == .authorized else {
            throw ConnectorError.permissionDenied("Apple Health access has not been granted.")
        }
    }

    private struct Stats {
        var average: Double?
        var minimum: Double?
        var maximum: Double?
    }

    private func sum(_ metric: HealthMetric, from start: Date, to end: Date) async -> Double? {
        guard let type = Self.quantityType(for: metric) else { return nil }
        let unit = Self.unit(for: metric)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                let value = statistics?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func average(_ metric: HealthMetric, from start: Date, to end: Date) async -> Double? {
        (await statistics(metric, from: start, to: end))?.average
    }

    private func statistics(_ metric: HealthMetric, from start: Date, to end: Date) async -> Stats? {
        guard let type = Self.quantityType(for: metric) else { return nil }
        let unit = Self.unit(for: metric)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMin, .discreteMax]
            ) { _, statistics, _ in
                guard let statistics else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Stats(
                    average: statistics.averageQuantity()?.doubleValue(for: unit),
                    minimum: statistics.minimumQuantity()?.doubleValue(for: unit),
                    maximum: statistics.maximumQuantity()?.doubleValue(for: unit)
                ))
            }
            store.execute(query)
        }
    }

    private func latest(_ metric: HealthMetric, from start: Date, to end: Date) async -> Double? {
        let items = (try? await samples(metric: metric, from: start, to: end, limit: 1)) ?? []
        return items.first?.value
    }

    private func sleepDuration(from start: Date, to end: Date) async -> Double {
        let items = (try? await sleepSamples(from: start, to: end, limit: 200)) ?? []
        return items.map(\.value).reduce(0, +)
    }

    private func sleepSamples(from start: Date, to end: Date, limit: Int) async throws -> [HealthSampleInfo] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        let asleep = samples.filter { Self.isAsleep($0.value) }
        return Array(asleep.prefix(limit)).map { sample in
            HealthSampleInfo(
                id: sample.uuid.uuidString,
                metric: .sleep,
                value: sample.endDate.timeIntervalSince(sample.startDate),
                unit: "s",
                start: sample.startDate,
                end: sample.endDate,
                sourceName: sample.sourceRevision.source.name
            )
        }
    }

    private func queryClinical(type: HKClinicalType, limit: Int) async throws -> [HKClinicalRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKClinicalRecord]) ?? [])
            }
            store.execute(query)
        }
    }

    // MARK: Type maps

    /// Activity and vitals only — safe to request with the basic HealthKit entitlement.
    private static var standardReadTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        for metric in HealthMetric.allCases {
            if let quantity = quantityType(for: metric) {
                types.insert(quantity)
            }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        return types
    }

    private static var allClinicalTypes: [HKClinicalType] {
        let ids: [HKClinicalTypeIdentifier] = [
            .allergyRecord, .conditionRecord, .immunizationRecord,
            .labResultRecord, .medicationRecord, .procedureRecord, .vitalSignRecord,
        ]
        return ids.compactMap { HKObjectType.clinicalType(forIdentifier: $0) }
    }

    private static func clinicalTypes(matching filter: String?) -> [HKClinicalType] {
        guard let filter else { return allClinicalTypes }
        let needle = filter.lowercased()
        return allClinicalTypes.filter { clinicalTypeLabel($0).lowercased().contains(needle) || needle.contains(clinicalTypeLabel($0).lowercased()) }
    }

    private static func clinicalTypeLabel(_ type: HKClinicalType) -> String {
        let id = type.identifier
        if id.contains("Allergy") { return "allergy" }
        if id.contains("Condition") { return "condition" }
        if id.contains("Immunization") { return "immunization" }
        if id.contains("LabResult") { return "lab" }
        if id.contains("Medication") { return "medication" }
        if id.contains("Procedure") { return "procedure" }
        if id.contains("VitalSign") { return "vital" }
        return id
    }

    private static func fhirBrief(_ record: HKClinicalRecord) -> String? {
        guard let data = try? record.fhirResource?.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let text = (json["text"] as? [String: Any])?["div"] as? String {
            let stripped = text
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? nil : stripped
        }
        if let code = ((json["code"] as? [String: Any])?["text"] as? String) {
            return code
        }
        return nil
    }

    private static func quantityType(for metric: HealthMetric) -> HKQuantityType? {
        let id: HKQuantityTypeIdentifier
        switch metric {
        case .steps: id = .stepCount
        case .distance: id = .distanceWalkingRunning
        case .activeEnergy: id = .activeEnergyBurned
        case .heartRate: id = .heartRate
        case .restingHeartRate: id = .restingHeartRate
        case .weight: id = .bodyMass
        case .bloodOxygen: id = .oxygenSaturation
        case .respiratoryRate: id = .respiratoryRate
        case .bloodPressureSystolic: id = .bloodPressureSystolic
        case .bloodPressureDiastolic: id = .bloodPressureDiastolic
        case .sleep: return nil
        }
        return HKObjectType.quantityType(forIdentifier: id)
    }

    private static func unit(for metric: HealthMetric) -> HKUnit {
        switch metric {
        case .steps: return .count()
        case .distance: return .meter()
        case .activeEnergy: return .kilocalorie()
        case .heartRate, .restingHeartRate, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .weight: return .gramUnit(with: .kilo)
        case .bloodOxygen: return .percent()
        case .bloodPressureSystolic, .bloodPressureDiastolic:
            return HKUnit.millimeterOfMercury()
        case .sleep: return .second()
        }
    }

    private static func unitLabel(for metric: HealthMetric) -> String {
        switch metric {
        case .steps: return "steps"
        case .distance: return "m"
        case .activeEnergy: return "kcal"
        case .heartRate, .restingHeartRate: return "bpm"
        case .sleep: return "s"
        case .weight: return "kg"
        case .bloodOxygen: return "fraction"
        case .respiratoryRate: return "breaths/min"
        case .bloodPressureSystolic, .bloodPressureDiastolic: return "mmHg"
        }
    }

    private static func isAsleep(_ value: Int) -> Bool {
        // HKCategoryValueSleepAnalysis: inBed=0, asleepUnspecified=1, awake=2,
        // asleepCore=3, asleepDeep=4, asleepREM=5.
        switch value {
        case 1, 3, 4, 5: return true
        default: return false
        }
    }

    private static func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .yoga: return "Yoga"
        case .hiking: return "Hiking"
        case .functionalStrengthTraining: return "Strength"
        case .traditionalStrengthTraining: return "Weights"
        case .highIntensityIntervalTraining: return "HIIT"
        case .dance: return "Dance"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .cooldown: return "Cooldown"
        case .coreTraining: return "Core"
        case .flexibility: return "Flexibility"
        case .mindAndBody: return "Mind and body"
        case .other: return "Other"
        default: return "Workout"
        }
    }
}

private extension Bundle {
    /// True when this build opted into Clinical Health Records.
    ///
    /// `ApplebotHealthRecordsEnabled` is set alongside the `health-records` entitlement in
    /// `project.yml`. Prefer the embedded profile when present so a mismatched build cannot
    /// request clinical types without the signed capability.
    var hasHealthRecordsEntitlement: Bool {
        if let url = url(forResource: "embedded.mobileprovision", withExtension: nil),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .ascii) {
            return text.contains("health-records")
        }
        return object(forInfoDictionaryKey: "ApplebotHealthRecordsEnabled") as? Bool ?? false
    }
}
#endif
