import XCTest
@testable import LLMKit

final class MemoryTests: XCTestCase {
    func testMergeDedupesAndPrefersNewerLonger() {
        let older = MemoryFact(text: "User has an interview on Friday", category: .event, updatedAt: Date(timeIntervalSince1970: 1))
        let newer = MemoryFact(text: "User has an interview on Friday at 3pm", category: .event, updatedAt: Date(timeIntervalSince1970: 2))
        let merged = MemoryBudget.merge(existing: [older], adding: [newer])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].text.contains("3pm"))
    }

    func testMergeRespectsCapAndPinned() {
        var existing: [MemoryFact] = []
        for i in 0..<MemoryBudget.maxStored {
            existing.append(MemoryFact(text: "User fact number \(i) about something durable", updatedAt: Date(timeIntervalSince1970: TimeInterval(i))))
        }
        let pinned = MemoryFact(text: "User's name is Alex", category: .person, pinned: true)
        let merged = MemoryBudget.merge(existing: existing, adding: [pinned, MemoryFact(text: "User likes short replies", category: .preference)])
        XCTAssertLessThanOrEqual(merged.count, MemoryBudget.maxStored)
        XCTAssertTrue(merged.contains(where: { $0.text.contains("Alex") && $0.pinned }))
    }

    func testRenderIncludesFactsAndStaysWithinBudget() throws {
        let facts = (0..<20).map { MemoryFact(text: "User remembers item \($0) with enough words to count") }
        let block = try XCTUnwrap(MemoryBudget.render(facts, maxTokens: 80))
        XCTAssertTrue(block.contains("Things you remember"))
        XCTAssertTrue(block.contains("User remembers item 0"))
        XCTAssertLessThanOrEqual(TokenEstimator.estimate(block), 120)
    }

    func testRenderNilWhenEmpty() {
        XCTAssertNil(MemoryBudget.render([]))
    }

    func testParseExtractionOutput() {
        XCTAssertEqual(MemoryExtractor.parse("NONE"), [])
        XCTAssertEqual(
            MemoryExtractor.parse("- User's name is Sam\n- User has an interview Friday\nNONE"),
            ["User's name is Sam", "User has an interview Friday"]
        )
        XCTAssertEqual(MemoryExtractor.parse("").count, 0)
    }

    func testHeuristicCapturesNameAndEvent() {
        let name = MemoryExtractor.heuristic(question: "My name is Jordan")
        XCTAssertTrue(name.contains(where: { $0.text.lowercased().contains("jordan") }))

        let sad = MemoryExtractor.heuristic(question: "I'm sad")
        XCTAssertFalse(sad.contains(where: { $0.category == .person }))

        let event = MemoryExtractor.heuristic(question: "I have an interview next Friday")
        XCTAssertTrue(event.contains(where: { $0.category == .event }))
    }

    func testInstructionsIncludeMemories() {
        let block = MemoryBudget.render([MemoryFact(text: "User's name is Sam", category: .person)])
        let text = PromptBuilder(tone: .warm).instructions(summary: nil, grounded: false, memories: block)
        XCTAssertTrue(text.contains("User's name is Sam"))
        XCTAssertTrue(text.contains("Things you remember"))
    }

    func testPipelineInjectsMemories() async throws {
        let engine = MockEngine(scripts: [.reply("Hi Sam.")])
        let memories = MemoryBudget.render([MemoryFact(text: "User's name is Sam", category: .person)])
        let pipeline = ChatPipeline(
            engine: engine,
            prompts: PromptBuilder(tone: .warm),
            memories: memories
        )
        var result: ChatResult?
        for try await event in pipeline.send(question: "Hi", state: ChatState(), useDocuments: false) {
            if case .finished(let finished) = event { result = finished }
        }
        XCTAssertNotNil(result)
        XCTAssertTrue(engine.requests[0].instructions.contains("User's name is Sam"))
    }

    func testExtractRequestMentionsNONE() {
        let request = MemoryExtractor().extractRequest(
            question: "My name is Sam", answer: "Nice to meet you, Sam.", existing: []
        )
        XCTAssertTrue(request.instructions.contains("NONE"))
        XCTAssertTrue(request.prompt.contains("My name is Sam"))
    }
}
