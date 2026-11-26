import XCTest
@testable import LLMKit

final class BehavioralProfileTests: XCTestCase {
    func testClassifyTravelAndFitness() {
        let topics = BehavioralSummarizer.classifyInterests(
            question: "Planning a flight to Lisbon and a gym workout after"
        )
        XCTAssertTrue(topics.contains(.travel))
        XCTAssertTrue(topics.contains(.fitness))
    }

    func testIngestDaysBuildsSleepAndExercise() {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        var samples: [BehavioralDaySample] = []
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: offset, to: base)!
            samples.append(BehavioralDaySample(
                day: day,
                sleepHours: 7.0 + Double(offset % 3) * 0.2,
                steps: 8_000,
                workoutCount: offset % 2,
                firstEventHour: 9,
                lastEventHour: 18
            ))
        }
        let profile = BehavioralSummarizer.ingestDays(samples, into: .empty)
        XCTAssertNotNil(profile.typicalSleepHours)
        XCTAssertEqual(profile.typicalSleepHours!, 7.0, accuracy: 1.0)
        XCTAssertNotNil(profile.exerciseDaysPerWeek)
        XCTAssertEqual(profile.workdayStartHour, 9)
        XCTAssertEqual(profile.workdayEndHour, 18)
        XCTAssertEqual(profile.sampleDays, 7)
    }

    func testIngestTurnBuildsInterestsTravelStressSpending() {
        var profile = BehavioralProfile()
        for _ in 0..<4 {
            profile = BehavioralSummarizer.ingestTurn(
                BehavioralTurnSignal(
                    question: "I'm so stressed about the budget and my flight tomorrow",
                    emotion: .anxiety,
                    intensity: 4
                ),
                into: profile
            )
        }
        // Short sleep on recent days so stress×sleep note can fire.
        let day = Date()
        profile = BehavioralSummarizer.ingestDays(
            [
                BehavioralDaySample(day: day, sleepHours: 5.0),
                BehavioralDaySample(day: day.addingTimeInterval(-86_400), sleepHours: 5.2),
                BehavioralDaySample(day: day.addingTimeInterval(-172_800), sleepHours: 5.5),
            ],
            into: profile
        )
        profile = BehavioralSummarizer.ingestTurn(
            BehavioralTurnSignal(question: "Still stressed and exhausted", emotion: .anxiety, intensity: 4),
            into: profile
        )

        XCTAssertFalse(profile.topInterests.isEmpty)
        XCTAssertTrue(profile.topInterests.contains { $0.topic == .travel || $0.topic == .finance })
        XCTAssertNotNil(profile.travelAffinity)
        XCTAssertNotNil(profile.spendingNote)
        XCTAssertNotNil(profile.stressNote)
    }

    func testRenderStaysWithinBudgetAndRespectsToggle() throws {
        let profile = BehavioralProfile(
            isEnabled: true,
            typicalSleepHours: 7.2,
            exerciseDaysPerWeek: 3.5,
            typicalSteps: 9_000,
            workdayStartHour: 9,
            workdayEndHour: 18,
            topInterests: [
                InterestSignal(topic: .travel, count: 5),
                InterestSignal(topic: .fitness, count: 3),
            ],
            travelAffinity: 0.7,
            stressNote: "Often stressed when sleep has been short; prefer calm, short replies.",
            spendingNote: "Often discusses money, budgets, or markets.",
            sampleDays: 7
        )
        let block = try XCTUnwrap(profile.render(maxTokens: BehavioralProfile.promptTokens))
        XCTAssertTrue(block.contains("Typical sleep"))
        XCTAssertTrue(block.contains("Travel"))
        XCTAssertLessThanOrEqual(TokenEstimator.estimate(block), BehavioralProfile.promptTokens + 20)

        var off = profile
        off.isEnabled = false
        XCTAssertNil(off.render())
    }

    func testContextBudgetNilWhenEmpty() {
        XCTAssertNil(BehavioralContextBudget.render(.empty))
    }
}
