import XCTest
@testable import LLMKit

final class PromptBuilderTests: XCTestCase {
    func testGroundedInstructionsIncludeRulesAndSummary() {
        let builder = PromptBuilder()
        let text = builder.instructions(summary: "User likes tea.", grounded: true)
        XCTAssertTrue(text.contains("ONLY the numbered context"))
        XCTAssertTrue(text.contains(PromptBuilder.notFoundPhrase))
        XCTAssertTrue(text.contains("User likes tea."))
    }

    func testUngroundedInstructionsOmitGroundingRules() {
        let text = PromptBuilder().instructions(summary: nil, grounded: false)
        XCTAssertFalse(text.contains("ONLY the numbered context"))
    }

    func testInstructionModesTrimCompanionPersona() {
        let warm = PromptBuilder(tone: .warm)
        let conversational = warm.instructions(summary: nil, grounded: false, mode: .conversational)
        let grounded = warm.instructions(summary: nil, grounded: true, mode: .grounded)
        let tools = warm.instructions(
            summary: nil, grounded: false, toolNote: PromptBuilder.toolInstructions(now: Date()), mode: .tools
        )
        XCTAssertTrue(conversational.contains("How are you feeling today?"))
        XCTAssertFalse(grounded.contains("How are you feeling today?"))
        XCTAssertTrue(grounded.contains("ONLY the numbered context"))
        XCTAssertFalse(tools.contains("How are you feeling today?"))
        XCTAssertTrue(tools.contains("untrusted data"))
        XCTAssertEqual(InstructionMode.resolve(intent: .documents, grounded: true, useTools: false), .grounded)
        XCTAssertEqual(InstructionMode.resolve(intent: .emotional, grounded: false, useTools: false), .emotional)
        XCTAssertEqual(InstructionMode.resolve(intent: .calendar, grounded: false, useTools: true), .tools)
    }

    func testNeedsGroundingRetry() {
        XCTAssertTrue(PromptBuilder.needsGroundingRetry(answer: "Just guess.", snippetCount: 2))
        XCTAssertFalse(PromptBuilder.needsGroundingRetry(answer: "Use reset [1].", snippetCount: 2))
        XCTAssertFalse(PromptBuilder.needsGroundingRetry(answer: PromptBuilder.notFoundPhrase, snippetCount: 0))
        XCTAssertTrue(PromptBuilder.needsGroundingRetry(answer: "Tuesday.", snippetCount: 0))
        XCTAssertTrue(PromptBuilder.needsGroundingRetry(answer: "   ", snippetCount: 1))
    }

    func testPromptNumbersSnippetsFromOne() {
        let snippets = [
            ContextSnippet(id: "a", title: "Manual", location: "Setup · p. 2", text: "Plug it in."),
            ContextSnippet(id: "b", title: "Notes", text: "Press reset."),
        ]
        let prompt = PromptBuilder().prompt(
            history: [Turn(role: .user, text: "hello"), Turn(role: .assistant, text: "hi")],
            snippets: snippets, question: "How?"
        )
        XCTAssertTrue(prompt.contains("[1] Manual (Setup · p. 2)\nPlug it in."))
        XCTAssertTrue(prompt.contains("[2] Notes\nPress reset."))
        XCTAssertTrue(prompt.contains("User: hello"))
        XCTAssertTrue(prompt.hasSuffix("Question: How?"))
    }

    func testCitationParsing() {
        XCTAssertEqual(PromptBuilder.citations(in: "Use the reset button [2]. Also see [1][2] and [10]."), [2, 1, 10])
        XCTAssertEqual(PromptBuilder.citations(in: "No markers here, but [a] and [] and [1 are not valid."), [])
        XCTAssertEqual(PromptBuilder.citations(in: ""), [])
    }
}
