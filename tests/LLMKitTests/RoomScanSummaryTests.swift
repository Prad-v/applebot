import XCTest
@testable import LLMKit

final class RoomScanSummaryTests: XCTestCase {
    func testFactSheetAndMechanicalSummary() {
        let facts = RoomScanFacts(
            wallCount: 4,
            doorCount: 1,
            windowCount: 2,
            openingCount: 0,
            objectLabels: ["sofa", "table", "sofa"]
        )
        let sheet = RoomScanNarrator.factSheet(facts)
        XCTAssertTrue(sheet.contains("Walls: 4"))
        XCTAssertTrue(sheet.contains("sofa"))
        let summary = RoomScanNarrator.mechanicalSummary(facts)
        XCTAssertTrue(summary.lowercased().contains("wall"))
        XCTAssertTrue(summary.lowercased().contains("door"))
        XCTAssertTrue(summary.contains("not for") || summary.lowercased().contains("construction"))
    }

    func testEmptyFacts() {
        let summary = RoomScanNarrator.mechanicalSummary(RoomScanFacts())
        XCTAssertTrue(summary.lowercased().contains("no clear") || summary.lowercased().contains("scan"))
    }

    func testNarrationRequest() {
        let facts = RoomScanFacts(wallCount: 3, doorCount: 1, objectLabels: ["bed"])
        let request = RoomScanNarrator.narrationRequest(facts: facts)
        XCTAssertTrue(request.prompt.contains("bed"))
        XCTAssertEqual(request.maximumResponseTokens, 180)
    }

    func testNormalizeAppendsSafety() {
        let facts = RoomScanFacts(wallCount: 2)
        let out = RoomScanNarrator.normalizeModelOutput("A small room with two walls.", facts: facts)
        XCTAssertTrue(out.contains("A small room"))
        XCTAssertTrue(out.lowercased().contains("not for") || out.lowercased().contains("approximate") || out.contains(RoomScanNarrator.safetyDisclaimer))
    }
}
