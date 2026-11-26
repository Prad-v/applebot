import XCTest
@testable import LLMKit

final class SurroundingsSceneTests: XCTestCase {
    func testFactSheetIncludesLabelsTextAndPeople() {
        let facts = SurroundingsFacts(
            classifications: ["kitchen (80%)", "indoor (60%)"],
            recognizedText: ["EXIT", "Room 12"],
            humanCount: 2,
            depthHint: "LiDAR available",
            sensorNotes: ["LiDAR depth assist: note"]
        )
        let sheet = SurroundingsNarrator.factSheet(facts)
        XCTAssertTrue(sheet.contains("kitchen"))
        XCTAssertTrue(sheet.contains("EXIT"))
        XCTAssertTrue(sheet.contains("2"))
        XCTAssertTrue(sheet.contains("LiDAR available"))
    }

    func testMechanicalNarrationEmpty() {
        let text = SurroundingsNarrator.mechanicalNarration(SurroundingsFacts())
        XCTAssertTrue(text.lowercased().contains("could not identify") || text.lowercased().contains("assistive"))
        XCTAssertTrue(text.contains("not for navigation") || text.lowercased().contains("assistive"))
    }

    func testMechanicalNarrationWithFacts() {
        let facts = SurroundingsFacts(
            classifications: ["office"],
            recognizedText: ["Welcome"],
            humanCount: 1
        )
        let text = SurroundingsNarrator.mechanicalNarration(facts)
        XCTAssertTrue(text.lowercased().contains("office"))
        XCTAssertTrue(text.lowercased().contains("person") || text.contains("1"))
        XCTAssertTrue(text.lowercased().contains("assistive") || text.lowercased().contains("not for"))
    }

    func testNormalizeAppendsSafetyWhenMissing() {
        let facts = SurroundingsFacts(classifications: ["hallway"])
        let out = SurroundingsNarrator.normalizeModelOutput("A hallway is ahead.", facts: facts)
        XCTAssertTrue(out.contains("A hallway is ahead."))
        XCTAssertTrue(out.lowercased().contains("assistive") || out.lowercased().contains("not for"))
    }

    func testNarrationRequestPromptUsesFacts() {
        let facts = SurroundingsFacts(classifications: ["bathroom"])
        let request = SurroundingsNarrator.narrationRequest(facts: facts)
        XCTAssertTrue(request.prompt.contains("bathroom"))
        XCTAssertTrue(request.instructions.lowercased().contains("blind") || request.instructions.lowercased().contains("low-vision"))
        XCTAssertEqual(request.maximumResponseTokens, 220)
    }

    func testMeaningfulChangeDetectsPeopleAndLabels() {
        let a = SurroundingsFacts(classifications: ["kitchen (80%)"], humanCount: 0)
        let b = SurroundingsFacts(classifications: ["kitchen (81%)"], humanCount: 0)
        // Confidence noise in the same root label should not count as change.
        XCTAssertFalse(SurroundingsNarrator.hasMeaningfulChange(from: a, to: b))

        let c = SurroundingsFacts(classifications: ["hallway (70%)"], humanCount: 1)
        XCTAssertTrue(SurroundingsNarrator.hasMeaningfulChange(from: a, to: c))
        XCTAssertTrue(SurroundingsNarrator.hasMeaningfulChange(from: nil, to: c))
    }

    func testLiveNarrationIsShort() {
        let prev = SurroundingsFacts(classifications: ["office"], humanCount: 0)
        let next = SurroundingsFacts(classifications: ["office"], recognizedText: ["EXIT"], humanCount: 1)
        let request = SurroundingsNarrator.liveNarrationRequest(facts: next, previous: prev)
        XCTAssertEqual(request.maximumResponseTokens, 80)
        XCTAssertTrue(request.prompt.contains("Previous facts"))
        let mechanical = SurroundingsNarrator.mechanicalLiveUpdate(previous: prev, current: next)
        XCTAssertTrue(mechanical.lowercased().contains("person") || mechanical.contains("1") || mechanical.lowercased().contains("exit"))
        XCTAssertFalse(mechanical.contains(SurroundingsNarrator.safetyDisclaimer))
    }
}
