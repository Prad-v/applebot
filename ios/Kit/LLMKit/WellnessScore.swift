import Foundation

/// Inputs for a transparent on-device wellness score (not a diagnosis).
public struct WellnessInputs: Sendable, Equatable {
    public var steps: Double?
    public var sleepHours: Double?
    public var restingHeartRate: Double?
    public var activeEnergyKcal: Double?
    public var workoutCount: Int

    public init(
        steps: Double? = nil,
        sleepHours: Double? = nil,
        restingHeartRate: Double? = nil,
        activeEnergyKcal: Double? = nil,
        workoutCount: Int = 0
    ) {
        self.steps = steps
        self.sleepHours = sleepHours
        self.restingHeartRate = restingHeartRate
        self.activeEnergyKcal = activeEnergyKcal
        self.workoutCount = workoutCount
    }
}

/// One scored dimension of the wellness score.
public struct WellnessComponent: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var points: Int
    public var maxPoints: Int
    public var detail: String

    public init(name: String, points: Int, maxPoints: Int, detail: String) {
        self.name = name
        self.points = max(0, min(points, maxPoints))
        self.maxPoints = maxPoints
        self.detail = detail
    }
}

/// Transparent 0–100 wellness score from local activity/vitals only.
public struct WellnessScore: Sendable, Equatable {
    public var total: Int
    public var components: [WellnessComponent]
    public var stepGoal: Double

    public init(total: Int, components: [WellnessComponent], stepGoal: Double = 8_000) {
        self.total = max(0, min(total, 100))
        self.components = components
        self.stepGoal = stepGoal
    }

    public var summaryLine: String {
        "Wellness score \(total)/100"
    }
}

/// Computes a wellness score with an explicit formula users can inspect.
public enum WellnessScoreCalculator {
    public static let defaultStepGoal: Double = 8_000

    public static func score(
        _ inputs: WellnessInputs,
        stepGoal: Double = defaultStepGoal
    ) -> WellnessScore {
        let goal = max(1, stepGoal)
        var components: [WellnessComponent] = []

        // Steps — up to 35 points (100% of goal = 35; extras don't add more).
        if let steps = inputs.steps {
            let ratio = min(steps / goal, 1.0)
            let points = Int((ratio * 35).rounded())
            let pct = Int((ratio * 100).rounded())
            components.append(WellnessComponent(
                name: "Steps",
                points: min(points, 35),
                maxPoints: 35,
                detail: "\(Int(steps.rounded())) steps (\(pct)% of \(Int(goal)) goal)"
            ))
        } else {
            components.append(WellnessComponent(
                name: "Steps", points: 0, maxPoints: 35, detail: "No step data"
            ))
        }

        // Sleep — up to 35 points; peak at 7–9 hours.
        if let sleep = inputs.sleepHours {
            let points: Int
            let detail: String
            if sleep >= 7, sleep <= 9 {
                points = 35
                detail = String(format: "%.1f h (in the 7–9 h sweet spot)", sleep)
            } else if sleep >= 6, sleep < 7 {
                points = 25
                detail = String(format: "%.1f h (a little short of 7 h)", sleep)
            } else if sleep > 9, sleep <= 10 {
                points = 28
                detail = String(format: "%.1f h (a little long)", sleep)
            } else if sleep >= 5 {
                points = 15
                detail = String(format: "%.1f h (outside 7–9 h)", sleep)
            } else {
                points = 5
                detail = String(format: "%.1f h (well below 7 h)", sleep)
            }
            components.append(WellnessComponent(
                name: "Sleep", points: points, maxPoints: 35, detail: detail
            ))
        } else {
            components.append(WellnessComponent(
                name: "Sleep", points: 0, maxPoints: 35, detail: "No sleep data"
            ))
        }

        // Resting heart rate — up to 15 points; lower within a common adult band scores higher.
        if let rhr = inputs.restingHeartRate {
            let points: Int
            let detail: String
            if rhr >= 50, rhr <= 70 {
                points = 15
                detail = String(format: "%.0f bpm (typical resting range)", rhr)
            } else if rhr > 70, rhr <= 85 {
                points = 10
                detail = String(format: "%.0f bpm (a bit elevated vs 50–70)", rhr)
            } else if rhr >= 40, rhr < 50 {
                points = 12
                detail = String(format: "%.0f bpm (low; athletes often sit here)", rhr)
            } else {
                points = 5
                detail = String(format: "%.0f bpm (outside common resting band)", rhr)
            }
            components.append(WellnessComponent(
                name: "Resting HR", points: points, maxPoints: 15, detail: detail
            ))
        } else {
            components.append(WellnessComponent(
                name: "Resting HR", points: 0, maxPoints: 15, detail: "No resting heart rate"
            ))
        }

        // Activity — up to 15 points from energy + workouts.
        var activityPoints = 0
        var activityDetail = "No active energy or workouts"
        if let energy = inputs.activeEnergyKcal {
            activityPoints += min(10, Int((energy / 400.0 * 10).rounded()))
            activityDetail = String(format: "%.0f kcal active", energy)
        }
        if inputs.workoutCount > 0 {
            activityPoints += min(5, inputs.workoutCount * 3)
            activityDetail += activityDetail.hasPrefix("No ")
                ? "\(inputs.workoutCount) workout(s)"
                : ", \(inputs.workoutCount) workout(s)"
        }
        activityPoints = min(15, activityPoints)
        components.append(WellnessComponent(
            name: "Activity", points: activityPoints, maxPoints: 15, detail: activityDetail
        ))

        let total = components.reduce(0) { $0 + $1.points }
        return WellnessScore(total: min(100, total), components: components, stepGoal: goal)
    }
}
