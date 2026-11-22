import Foundation

/// A spoken capture turned into a structured note for the document library (RAG pack).
public struct StructuredVoiceNote: Sendable, Equatable {
    public var title: String
    public var body: String
    public var tags: [String]
    public var pack: String

    public static let defaultPack = "Voice notes"

    public init(title: String, body: String, tags: [String] = [], pack: String = defaultPack) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.pack = pack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultPack
            : pack.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Document title used when ingesting into the knowledge base.
    public var documentTitle: String {
        "\(pack) / \(title)"
    }

    /// Full text stored and indexed.
    public var documentText: String {
        var parts: [String] = ["# \(title)", "", body]
        if !tags.isEmpty {
            parts.append("")
            parts.append("Tags: " + tags.joined(separator: ", "))
        }
        return parts.joined(separator: "\n")
    }
}

/// Portable structuring of a voice transcript into a note. Heuristic by default; optional model polish.
public struct VoiceNoteStructurer: Sendable {
    public init() {}

    /// Fast local structuring — no model call.
    public static func structure(_ transcript: String, now: Date = Date(), pack: String = StructuredVoiceNote.defaultPack) -> StructuredVoiceNote {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return StructuredVoiceNote(title: "Empty note", body: "", pack: pack)
        }

        let sentences = splitSentences(cleaned)
        let title: String
        let body: String
        if let first = sentences.first, first.count <= 80 {
            title = capitalize(first.trimmingCharacters(in: CharacterSet(charactersIn: ".!?")))
            let rest = sentences.dropFirst()
            body = rest.isEmpty ? cleaned : rest.map { "• \($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
        } else {
            let stamp = isoDay(now)
            title = "Voice note \(stamp)"
            body = sentences.map { "• \($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
        }

        var tags: [String] = ["voice"]
        let lowered = cleaned.lowercased()
        if lowered.contains("meeting") || lowered.contains("standup") { tags.append("meeting") }
        if lowered.contains("idea") || lowered.contains("brainstorm") { tags.append("idea") }
        if lowered.contains("todo") || lowered.contains("to do") || lowered.contains("remind") { tags.append("todo") }

        return StructuredVoiceNote(title: String(title.prefix(80)), body: body, tags: tags, pack: pack)
    }

    /// Optional model request to polish a heuristic note.
    public func polishRequest(transcript: String) -> LLMRequest {
        LLMRequest(
            instructions: "Turn the user's spoken transcript into a short structured note. "
                + "Output exactly three lines:\n"
                + "TITLE: <short title>\n"
                + "BODY: <2-6 short bullet lines separated by | >\n"
                + "TAGS: <comma-separated tags>\n"
                + "Do not invent facts that were not said.",
            prompt: TokenEstimator.truncate(transcript, toTokens: 400)
        )
    }

    public static func parsePolished(_ raw: String, fallback transcript: String, now: Date = Date()) -> StructuredVoiceNote {
        let base = structure(transcript, now: now)
        var title = base.title
        var body = base.body
        var tags = base.tags

        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("title:") {
                title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if lowered.hasPrefix("body:") {
                let content = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                body = content.split(separator: "|").map { "• \($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
            } else if lowered.hasPrefix("tags:") {
                tags = String(trimmed.dropFirst(5))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
        return StructuredVoiceNote(title: title, body: body, tags: tags)
    }

    private static func splitSentences(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: { ".!?\n".contains($0) }).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
    }

    private static func capitalize(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
