import XCTest
import LLMKit
@testable import RAGKit

final class ChunkerTests: XCTestCase {
    private func sentenceParagraph(_ count: Int, prefix: String = "Sentence") -> String {
        (0..<count).map { "\(prefix) number \($0) talks about a distinct topic here." }.joined(separator: " ")
    }

    func testSmallDocumentIsOneChunk() {
        let chunks = Chunker().chunk(text: "Just one short paragraph of text.")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, "Just one short paragraph of text.")
        XCTAssertNil(chunks[0].heading)
    }

    func testHeadingsStartNewChunksAndAreRecorded() {
        let text = """
        # Setup
        Plug it in and wait.

        ## Reset
        Hold the button.
        """
        let chunks = Chunker().chunk(text: text)
        XCTAssertEqual(chunks.map(\.heading), ["Setup", "Reset"])
        XCTAssertEqual(chunks[0].text, "Plug it in and wait.")
        XCTAssertEqual(chunks[1].text, "Hold the button.")
    }

    func testAllCapsLineIsTreatedAsHeading() {
        let chunks = Chunker().chunk(text: "WARRANTY TERMS\n\nCovered for two years.")
        XCTAssertEqual(chunks.first?.heading, "Warranty Terms")
    }

    func testLongTextIsSplitWithinBudget() {
        let config = ChunkerConfig(targetTokens: 120, maxTokens: 160, overlapFraction: 0.15, minTokens: 20)
        let chunks = Chunker(config: config).chunk(text: sentenceParagraph(60))
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(TokenEstimator.estimate(chunk.text), config.maxTokens, "chunk too large")
        }
    }

    func testAllContentIsPreserved() {
        let config = ChunkerConfig(targetTokens: 100, maxTokens: 140, overlapFraction: 0.15, minTokens: 10)
        let text = sentenceParagraph(40)
        let joined = Chunker(config: config).chunk(text: text).map(\.text).joined(separator: " ")
        for index in 0..<40 {
            XCTAssertTrue(joined.contains("Sentence number \(index) "), "lost sentence \(index)")
        }
    }

    func testOverlapRepeatsTrailingSentence() {
        let config = ChunkerConfig(targetTokens: 100, maxTokens: 140, overlapFraction: 0.3, minTokens: 10)
        let chunks = Chunker(config: config).chunk(text: sentenceParagraph(30))
        XCTAssertGreaterThan(chunks.count, 1)
        let firstSentences = Chunker.sentences(of: chunks[0].text)
        let lastOfFirst = try! XCTUnwrap(firstSentences.last)
        XCTAssertTrue(chunks[1].text.contains(lastOfFirst), "second chunk should begin with overlap")
    }

    func testOversizedSentenceIsSplitByWords() {
        let config = ChunkerConfig(targetTokens: 60, maxTokens: 80, overlapFraction: 0, minTokens: 5)
        let monster = Array(repeating: "wordy", count: 400).joined(separator: " ")
        let chunks = Chunker(config: config).chunk(text: monster)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks { XCTAssertLessThanOrEqual(TokenEstimator.estimate(chunk.text), 80) }
    }

    func testPagesArePropagated() {
        let blocks = [
            TextBlock(text: "First page text.", page: 1),
            TextBlock(text: "# Chapter\nSecond page text.", page: 2),
        ]
        let chunks = Chunker().chunk(blocks: blocks)
        XCTAssertEqual(chunks.first?.page, 1)
        XCTAssertEqual(chunks.last?.page, 2)
        XCTAssertEqual(chunks.last?.heading, "Chapter")
    }

    func testEmptyInputProducesNoChunks() {
        XCTAssertTrue(Chunker().chunk(text: "  \n\n  ").isEmpty)
    }

    func testChunkLocationLabelAndSearchText() {
        let chunk = Chunk(documentID: UUID(), ordinal: 0, text: "Body", page: 3, heading: "Install")
        XCTAssertEqual(chunk.locationLabel, "Install · p. 3")
        XCTAssertEqual(chunk.searchText, "Install\nBody")
    }
}
