import Foundation
import Observation
import ConnectorKit
import LLMKit

/// Loads Apple Health summaries for the Health tab and builds wellness insights.
@MainActor
@Observable
final class HealthDashboardController {
    private(set) var permission: PermissionState = .notDetermined
    private(set) var isAvailable = true
    private(set) var isLoading = false
    private(set) var isRefreshingInsight = false
    private(set) var errorMessage: String?
    private(set) var today: HealthSummaryInfo?
    private(set) var workouts: [HealthWorkoutInfo] = []
    private(set) var clinicalRecords: [HealthClinicalRecordInfo] = []
    private(set) var score: WellnessScore?
    private(set) var weekPoints: [WellnessDayPoint] = []
    private(set) var insightNarrative: String?
    private(set) var lastRefreshed: Date?

    @ObservationIgnored private var provider: (any HealthKitProvider)?
    @ObservationIgnored private var engine: (() -> any LLMEngine)?

    var isConnected: Bool {
        permission == .authorized
    }

    var activityLine: String? {
        guard let today else { return nil }
        var parts: [String] = []
        if let steps = today.steps {
            parts.append("\(Int(steps.rounded())) steps today")
        }
        if let sleep = today.sleepHours {
            parts.append(String(format: "%.1fh sleep", sleep))
        }
        if let rhr = today.restingHeartRate {
            parts.append(String(format: "%.0f bpm resting", rhr))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Compact lines for the morning unlock brief.
    var briefHealthLines: [String] {
        DailyBriefBuilder.healthLines(
            steps: today?.steps,
            sleepHours: today?.sleepHours,
            restingHeartRate: today?.restingHeartRate,
            wellnessScore: score?.total
        )
    }

    func configure(provider: any HealthKitProvider, engine: @escaping () -> any LLMEngine) {
        self.provider = provider
        self.engine = engine
    }

    func refreshStatus() async {
        guard let provider else {
            isAvailable = false
            permission = .restricted
            return
        }
        isAvailable = await provider.isAvailable()
        permission = await provider.permission()
    }

    func connect() async {
        guard let provider else { return }
        errorMessage = nil
        do {
            _ = try await provider.requestAccess()
            await refreshStatus()
            await refresh()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await refreshStatus()
        }
    }

    func refresh(medications: [MedicationInfo] = [], includeInsight: Bool = true) async {
        guard let provider else { return }
        await refreshStatus()
        guard permission == .authorized else {
            today = nil
            workouts = []
            clinicalRecords = []
            score = nil
            weekPoints = []
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let calendar = Calendar.current
        let now = Date()
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        do {
            async let summary = provider.summary(from: start, to: end)
            async let workoutList = provider.workouts(from: start, to: end, limit: 8)
            async let records = provider.clinicalRecords(recordType: nil, limit: 20)
            async let week = loadWeekPoints(provider: provider, calendar: calendar, endingOn: start)
            today = try await summary
            workouts = try await workoutList
            clinicalRecords = try await records
            weekPoints = try await week
            lastRefreshed = Date()

            if let today {
                score = WellnessScoreCalculator.score(WellnessInputs(
                    steps: today.steps,
                    sleepHours: today.sleepHours,
                    restingHeartRate: today.restingHeartRate,
                    activeEnergyKcal: today.activeEnergyKcal,
                    workoutCount: today.workoutCount
                ))
            } else {
                score = nil
            }

            if includeInsight {
                await regenerateInsight(medications: medications)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearInsights() {
        insightNarrative = nil
        score = nil
        today = nil
        workouts = []
        clinicalRecords = []
        weekPoints = []
        lastRefreshed = nil
        errorMessage = nil
    }

    func regenerateInsight(medications: [MedicationInfo]) async {
        guard let score, let engine else { return }
        isRefreshingInsight = true
        defer { isRefreshingInsight = false }
        let request = HealthInsightBuilder.narrativeRequest(
            score: score,
            activityLine: activityLine ?? "",
            medications: medications
        )
        do {
            let raw = try await engine().respond(request)
            insightNarrative = Self.normalizeInsight(raw)
        } catch {
            if insightNarrative == nil {
                insightNarrative = fallbackInsight(score: score, medications: medications)
            }
        }
    }

    /// Prompt for Chat, embedding today's score/activity when available.
    func askPrompt(kind: HealthAskKind, medications: [MedicationInfo]) -> String {
        switch kind {
        case .score:
            var parts = ["Explain my wellness score and today's activity in plain language."]
            if let score { parts.append("Score: \(score.total)/100.") }
            if let activityLine { parts.append(activityLine + ".") }
            parts.append("Not medical advice.")
            return parts.joined(separator: " ")
        case .medications:
            let names = medications.filter(\.userConfirmed).prefix(8).map(\.displayLine)
            if names.isEmpty {
                return "I haven't saved medications in Applebot yet. What should I know about tracking meds privately on-device? Not medical advice."
            }
            return "Give general information people often associate with these medications I saved in Applebot: "
                + names.joined(separator: "; ")
                + ". Do not tell me to change doses. Not medical advice."
        case .week:
            let trail = weekPoints.suffix(7).map { point in
                let day = point.day.formatted(.dateTime.weekday(.abbreviated))
                return "\(day) \(point.score)"
            }.joined(separator: ", ")
            return "Summarize my last week of wellness scores (\(trail.isEmpty ? "no trend data yet" : trail)). "
                + "Keep it short and not medical advice."
        }
    }

    private func loadWeekPoints(
        provider: any HealthKitProvider,
        calendar: Calendar,
        endingOn todayStart: Date
    ) async throws -> [WellnessDayPoint] {
        var points: [WellnessDayPoint] = []
        for offset in (0..<7).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { continue }
            let summary = try await provider.summary(from: day, to: next)
            let scored = WellnessScoreCalculator.score(WellnessInputs(
                steps: summary.steps,
                sleepHours: summary.sleepHours,
                restingHeartRate: summary.restingHeartRate,
                activeEnergyKcal: summary.activeEnergyKcal,
                workoutCount: summary.workoutCount
            ))
            points.append(WellnessDayPoint(
                day: day,
                score: scored.total,
                steps: summary.steps,
                sleepHours: summary.sleepHours,
                workoutCount: summary.workoutCount
            ))
        }
        return points
    }

    private static func normalizeInsight(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("DISCLAIMER:") {
            return trimmed
        }
        return trimmed + "\n\nDISCLAIMER: " + HealthInsightBuilder.userFacingDisclaimer
    }

    private func fallbackInsight(score: WellnessScore, medications: [MedicationInfo]) -> String {
        var parts = [
            "Your wellness score is \(score.total) out of 100 based on steps, sleep, resting heart rate, and activity on this iPhone.",
        ]
        let confirmed = medications.filter(\.userConfirmed)
        if !confirmed.isEmpty {
            let names = confirmed.prefix(5).map(\.name).joined(separator: ", ")
            parts.append(
                "Saved medications in Applebot: \(names). "
                    + "Ask in chat for general information — always verify with a clinician or pharmacist."
            )
        }
        parts.append("DISCLAIMER: " + HealthInsightBuilder.userFacingDisclaimer)
        return parts.joined(separator: "\n\n")
    }
}

enum HealthAskKind: String, Sendable {
    case score
    case medications
    case week
}
