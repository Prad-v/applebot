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
