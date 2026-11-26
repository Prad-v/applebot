import XCTest
@testable import LLMKit

final class HealthMedicationTests: XCTestCase {
    func testWellnessScorePeaksWithBalancedInputs() {
        let score = WellnessScoreCalculator.score(WellnessInputs(
            steps: 8_000,
            sleepHours: 7.5,
            restingHeartRate: 60,
            activeEnergyKcal: 400,
            workoutCount: 1
        ))
        XCTAssertGreaterThanOrEqual(score.total, 85)
        XCTAssertEqual(score.components.count, 4)
        XCTAssertTrue(score.components.contains { $0.name == "Steps" && $0.points == 35 })
        XCTAssertTrue(score.components.contains { $0.name == "Sleep" && $0.points == 35 })
    }

    func testWellnessScoreHandlesMissingData() {
        let score = WellnessScoreCalculator.score(WellnessInputs())
        XCTAssertEqual(score.total, 0)
        XCTAssertTrue(score.components.allSatisfy { $0.points == 0 })
    }

    func testMedicationParserExtractsDoseAndFrequency() {
        let ocr = """
        Metformin HCl
        500 mg
        Take twice daily with meals
        CVS Pharmacy
        """
        let draft = MedicationParser.draft(fromOCR: ocr)
        XCTAssertTrue(draft.name.lowercased().contains("metformin"))
        XCTAssertTrue(draft.dose.lowercased().contains("500"))
        XCTAssertTrue(draft.frequency.lowercased().contains("twice") || draft.frequency.lowercased().contains("daily"))
        XCTAssertFalse(draft.ocrRawText.isEmpty)
    }

    func testMedicationParserParsePolished() {
        let raw = """
        NAME: Lisinopril
        DOSE: 10 mg
        FREQUENCY: once daily
        NOTES: none
        """
        let draft = MedicationParser.parsePolished(raw, fallback: "LISINOPRIL 10 MG TABLET")
        XCTAssertEqual(draft.name, "Lisinopril")
        XCTAssertEqual(draft.dose, "10 mg")
        XCTAssertEqual(draft.frequency, "once daily")
        XCTAssertTrue(draft.notes.isEmpty)
    }

    func testHealthContextBudgetRendersConfirmedMeds() {
        let meds = [
            MedicationInfo(name: "Metformin", dose: "500 mg", frequency: "BID", userConfirmed: true),
            MedicationInfo(name: "Draft", userConfirmed: false),
        ]
        let score = WellnessScoreCalculator.score(WellnessInputs(steps: 5_000, sleepHours: 7))
        let block = HealthContextBudget.render(
            medications: meds,
            score: score,
            activityLine: "5000 steps today"
        )
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("Metformin"))
        XCTAssertFalse(block!.contains("Draft"))
        XCTAssertTrue(block!.localizedCaseInsensitiveContains("not a medical"))
    }

    func testInsightPromptIncludesDisclaimerInstruction() {
        let score = WellnessScore(total: 70, components: [
            WellnessComponent(name: "Steps", points: 20, maxPoints: 35, detail: "5k"),
        ])
        let request = HealthInsightBuilder.narrativeRequest(
            score: score,
            activityLine: "5k steps",
            medications: [MedicationInfo(name: "Ibuprofen", dose: "200 mg")]
        )
        XCTAssertTrue(request.instructions.contains("DISCLAIMER"))
        XCTAssertTrue(request.prompt.contains("Ibuprofen"))
        XCTAssertTrue(request.prompt.contains("70"))
    }

    func testIntentRouterHealthForMedicationsAndScore() {
        let router = IntentRouter()
        XCTAssertEqual(router.route(question: "What are my medications?", useDocuments: false), .health)
        XCTAssertEqual(router.route(question: "What's my wellness score?", useDocuments: false), .health)
        XCTAssertEqual(router.route(question: "Any side effects I should know?", useDocuments: false), .health)
    }

    func testMedicationReminderTimeNormalization() {
        XCTAssertEqual(MedicationInfo.normalizeTime("8:00"), "08:00")
        XCTAssertEqual(MedicationInfo.normalizeTime("20:30"), "20:30")
        XCTAssertNil(MedicationInfo.normalizeTime("25:00"))
        XCTAssertEqual(
            MedicationInfo.normalizeTimes(["20:00", "8:00", "20:00", "bad"]),
            ["08:00", "20:00"]
        )
        var med = MedicationInfo(name: "Test", remindersEnabled: true, reminderTimes: ["9:00"])
        XCTAssertEqual(med.reminderTimes, ["09:00"])
        XCTAssertFalse(med.takenToday())
        med.lastTakenAt = Date()
        XCTAssertTrue(med.takenToday())
    }

    func testMedicationBestMatchByName() {
        let meds = [
            MedicationInfo(name: "Metformin", dose: "500 mg"),
            MedicationInfo(name: "Lisinopril", dose: "10 mg"),
        ]
        XCTAssertEqual(MedicationInfo.bestMatch(named: "metformin", in: meds)?.name, "Metformin")
        XCTAssertEqual(MedicationInfo.bestMatch(named: "lisi", in: meds)?.name, "Lisinopril")
        XCTAssertNil(MedicationInfo.bestMatch(named: "ibuprofen", in: meds))
    }
}
