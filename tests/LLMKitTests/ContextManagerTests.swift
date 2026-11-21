import XCTest
@testable import LLMKit

final class ContextManagerTests: XCTestCase {
    private func turns(_ count: Int, words: Int = 60) -> [Turn] {
        (0..<count).flatMap { index -> [Turn] in
            let filler = Array(repeating: "word", count: words).joined(separator: " ")
            return [
                Turn(role: .user, text: "q\(index) \(filler)"),
                Turn(role: .assistant, text: "a\(index) \(filler)"),
            ]
        }
    }

    func testTokenEstimateIsConservativeAndMonotonic() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        XCTAssertGreaterThan(TokenEstimator.estimate("hello world"), 2)
        XCTAssertLessThan(TokenEstimator.estimate("short"), TokenEstimator.estimate("a much longer sentence of text"))
    }

    func testTruncateRespectsBudget() {
        let long = Array(repeating: "lorem", count: 500).joined(separator: " ")
        let cut = TokenEstimator.truncate(long, toTokens: 50)
        XCTAssertLessThanOrEqual(TokenEstimator.estimate(cut), 52)
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    func testShortConversationIsUntouched() {
        let manager = ContextManager()
        let history = turns(2, words: 5)
        let fit = manager.fit(instructions: "be nice", history: history, snippets: [], question: "hi")
        XCTAssertEqual(fit.history, history)
        XCTAssertTrue(fit.dropped.isEmpty)
    }

    func testOldestTurnsAreDroppedFirstAndHistoryStartsWithUser() {
        let manager = ContextManager()
        let history = turns(20)
        let fit = manager.fit(instructions: "be nice", history: history, snippets: [], question: "hi")
        XCTAssertFalse(fit.dropped.isEmpty)
        XCTAssertEqual(fit.dropped.first, history.first)
        XCTAssertEqual(fit.history.first?.role, .user)
        XCTAssertEqual(fit.history.last, history.last)
        XCTAssertEqual(fit.history.count + fit.dropped.count, history.count)
    }

    func testEstimatedTotalStaysUnderUsableWindow() {
        let manager = ContextManager()
        let snippets = (0..<8).map {
            ContextSnippet(id: "\($0)", title: "Doc", text: String(repeating: "alpha beta gamma ", count: 200))
        }
        let fit = manager.fit(instructions: "rules", history: turns(10), snippets: snippets, question: "what?")
        XCTAssertLessThanOrEqual(fit.estimatedTokens, manager.usableTokens)
        XCTAssertFalse(fit.snippets.isEmpty)
        XCTAssertLessThan(fit.snippets.count, snippets.count)
    }

    func testSnippetsKeepRankOrder() {
        let manager = ContextManager()
        let snippets = (0..<3).map { ContextSnippet(id: "\($0)", title: "Doc \($0)", text: "short text \($0)") }
        let fit = manager.fit(instructions: "r", history: [], snippets: snippets, question: "q")
        XCTAssertEqual(fit.snippets.map(\.id), ["0", "1", "2"])
    }

    func testPressureShrinksBudget() {
        let manager = ContextManager()
        let history = turns(8, words: 40)
        let relaxed = manager.fit(instructions: "r", history: history, snippets: [], question: "q", pressure: 1.0)
        let tight = manager.fit(instructions: "r", history: history, snippets: [], question: "q", pressure: 3.0)
        XCTAssertGreaterThanOrEqual(tight.dropped.count, relaxed.dropped.count)
        XCTAssertLessThan(tight.history.count, history.count)
    }

    func testShouldCompact() {
        let manager = ContextManager()
        XCTAssertFalse(manager.shouldCompact(history: turns(1, words: 5)))
        XCTAssertTrue(manager.shouldCompact(history: turns(20)))
    }
}
