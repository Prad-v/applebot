import Foundation
import LLMKit

public struct ChunkerConfig: Sendable, Equatable {
    /// Soft target; a chunk is closed once adding the next unit would exceed this.
    public var targetTokens: Int
    /// Hard cap for a single unit; larger paragraphs/sentences are split further.
    public var maxTokens: Int
    /// Fraction of the target repeated at the start of the next chunk (sentence-level overlap).
    public var overlapFraction: Double
    /// Trailing chunks smaller than this are merged into the previous one when possible.
    public var minTokens: Int

    public init(targetTokens: Int = 250, maxTokens: Int = 320, overlapFraction: Double = 0.15, minTokens: Int = 30) {
        self.targetTokens = targetTokens
        self.maxTokens = maxTokens
        self.overlapFraction = overlapFraction
        self.minTokens = minTokens
    }
}

/// A chunk before it is assigned to a document.
public struct ChunkDraft: Sendable, Equatable {
    public var text: String
    public var page: Int?
    public var heading: String?
}

/// Heading-aware, sentence-respecting chunker.
public struct Chunker: Sendable {
    public var config: ChunkerConfig

    public init(config: ChunkerConfig = ChunkerConfig()) {
        self.config = config
    }

    public func chunk(text: String) -> [ChunkDraft] {
        chunk(blocks: [TextBlock(text: text)])
    }

    public func chunk(blocks: [TextBlock]) -> [ChunkDraft] {
        var drafts: [ChunkDraft] = []
        var buffer: [Unit] = []
        var bufferTokens = 0
        var heading: String?

        func flush(keepOverlap: Bool) {
            guard !buffer.isEmpty else { return }
            let text = buffer.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: " \n", with: "\n")
            drafts.append(ChunkDraft(text: text, page: buffer.first?.page, heading: buffer.first?.heading))

            var carried: [Unit] = []
            if keepOverlap {
                let overlapBudget = Int(Double(config.targetTokens) * config.overlapFraction)
                var used = 0
                for unit in buffer.reversed() {
                    if unit.tokens + used > overlapBudget { break }
                    carried.insert(unit, at: 0)
                    used += unit.tokens
                }
                // Do not carry the whole buffer; that would loop without progress.
                if carried.count == buffer.count { carried.removeFirst() }
            }
            buffer = carried
            bufferTokens = carried.reduce(0) { $0 + $1.tokens }
        }

        for block in blocks {
            for segment in Self.segments(of: block.text) {
                switch segment {
                case .heading(let title):
                    flush(keepOverlap: false)
                    buffer = []; bufferTokens = 0
                    heading = title
                case .paragraph(let paragraph):
                    for unitText in splitToUnits(paragraph) {
                        let unit = Unit(
                            text: unitText, tokens: TokenEstimator.estimate(unitText),
                            page: block.page, heading: heading
                        )
                        if bufferTokens + unit.tokens > config.targetTokens, !buffer.isEmpty {
                            flush(keepOverlap: true)
                        }
                        buffer.append(unit)
                        bufferTokens += unit.tokens
                    }
                }
            }
        }
        flush(keepOverlap: false)
        return mergeTinyTail(drafts)
    }

    // MARK: - Internals

    private struct Unit {
        var text: String
        var tokens: Int
        var page: Int?
        var heading: String?
    }

    enum Segment {
        case heading(String)
        case paragraph(String)
    }

    /// Split raw text into headings and paragraphs.
    static func segments(of text: String) -> [Segment] {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result: [Segment] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraphLines = []
        }

        for rawLine in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if let title = headingTitle(line) {
                flushParagraph()
                result.append(.heading(title))
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        return result
    }

    /// Markdown headings (`# Title`) and short ALL-CAPS lines are treated as headings.
    static func headingTitle(_ line: String) -> String? {
        if line.hasPrefix("#") {
            let stripped = line.drop(while: { $0 == "#" })
            if stripped.first == " " {
                let title = stripped.trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : title
            }
        }
        if line.count >= 3, line.count <= 60,
           line.contains(where: \.isLetter),
           !line.contains(where: { $0.isLowercase }),
           !".!?,;:".contains(line.last ?? " ") {
            return line.capitalized
        }
        return nil
    }

    /// Break a paragraph into units no larger than `maxTokens`: whole paragraph, else sentences,
    /// else fixed word windows.
    private func splitToUnits(_ paragraph: String) -> [String] {
        if TokenEstimator.estimate(paragraph) <= config.maxTokens { return [paragraph] }
        var units: [String] = []
        for sentence in Self.sentences(of: paragraph) {
            if TokenEstimator.estimate(sentence) <= config.maxTokens {
                units.append(sentence)
            } else {
                units.append(contentsOf: splitByWords(sentence))
            }
        }
        return units
    }

    private func splitByWords(_ text: String) -> [String] {
        let maxCharacters = Int(Double(config.maxTokens) * TokenEstimator.charactersPerToken)
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.count + word.count + 1 > maxCharacters, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + word
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    static func sentences(of text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let isTerminator = ".!?".contains(character)
            let nextIsBoundary = index + 1 >= characters.count || characters[index + 1] == " "
            if isTerminator, nextIsBoundary {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// Merge a tiny last chunk into its predecessor when they share a heading and fit.
    private func mergeTinyTail(_ drafts: [ChunkDraft]) -> [ChunkDraft] {
        guard drafts.count >= 2, let last = drafts.last else { return drafts }
        let previous = drafts[drafts.count - 2]
        guard TokenEstimator.estimate(last.text) < config.minTokens,
              previous.heading == last.heading,
              TokenEstimator.estimate(previous.text) + TokenEstimator.estimate(last.text) <= config.maxTokens
        else { return drafts }
        var merged = Array(drafts.dropLast(2))
        merged.append(ChunkDraft(text: previous.text + " " + last.text, page: previous.page, heading: previous.heading))
        return merged
    }
}
