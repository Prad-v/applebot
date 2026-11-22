import XCTest
@testable import LLMKit

final class ContinuityTests: XCTestCase {
    func testCheckInSuggestsOpenLoop() throws {
        let facts = [
            MemoryFact(text: "User has an ongoing concern: sleep schedule", category: .openLoop, confidence: 0.9)
        ]
        let suggestion = try XCTUnwrap(CheckInPlanner.suggest(facts: facts, lastCheckInAt: nil))
        XCTAssertTrue(suggestion.prompt.lowercased().contains("sleep") || suggestion.factText.contains("sleep"))
    }

    func testCheckInRespectsCooldown() {
        let facts = [
            MemoryFact(text: "User has an ongoing concern: sleep schedule", category: .openLoop)
        ]
        let recent = Date().addingTimeInterval(-86_400)
        XCTAssertNil(CheckInPlanner.suggest(facts: facts, lastCheckInAt: recent))
    }

    func testRetrievalWeightsHelpfulVectorOnly() {
        let start = RetrievalWeights.default
        let next = start.applying(helpful: true, citedHadVector: true, citedHadKeyword: false)
        XCTAssertGreaterThan(next.vectorWeight, start.vectorWeight)
        XCTAssertEqual(next.helpfulCount, 1)
    }

    func testRetrievalWeightsUnhelpfulKeywordOnly() {
        let start = RetrievalWeights.default
        let next = start.applying(helpful: false, citedHadVector: false, citedHadKeyword: true)
        XCTAssertLessThan(next.keywordWeight, start.keywordWeight)
        XCTAssertEqual(next.unhelpfulCount, 1)
    }

    func testFamilyProfileRegistry() {
        var registry = FamilyProfileRegistry.bootstrap(defaultName: "Sam")
        XCTAssertEqual(registry.profiles.count, 1)
        let kid = registry.add(name: "Alex")
        XCTAssertTrue(registry.select(kid.id))
        XCTAssertEqual(registry.active.name, "Alex")
        XCTAssertTrue(registry.remove(id: kid.id))
        XCTAssertEqual(registry.active.name, "Sam")
    }

    func testAutomationDueWeekly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // 2026-11-22 is a Sunday.
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22))!
        let recipe = AutomationRecipe(title: "Week plan", prompt: "Plan", cadence: .weeklySunday)
        XCTAssertTrue(recipe.cadence.isDue(on: sunday, calendar: calendar, lastRunDayKey: nil))
        let marked = AutomationScheduler.markRan(recipe, on: sunday, calendar: calendar)
        XCTAssertFalse(marked.cadence.isDue(on: sunday, calendar: calendar, lastRunDayKey: marked.lastRunDayKey))
    }

    func testVaultRoundTripCodec() throws {
        let payload = PersonalVaultPayload(
            profileName: "Sam",
            personalProfile: PersonalProfile(displayName: "Sam"),
            styleCard: StyleCard(traits: "warm", isEnabled: true),
            memories: [MemoryFact(text: "User's name is Sam", category: .person)],
            automations: AutomationRecipe.templates
        )
        let data = try PersonalVaultCodec.encodePayload(payload)
        let decoded = try PersonalVaultCodec.decodePayload(data)
        XCTAssertEqual(decoded.profileName, "Sam")
        XCTAssertEqual(decoded.memories.count, 1)
        XCTAssertEqual(decoded.personalProfile.displayName, "Sam")
    }
}
