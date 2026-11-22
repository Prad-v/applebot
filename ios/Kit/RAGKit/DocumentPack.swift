import Foundation

/// Lightweight “pack” naming for documents via a title prefix: `"Pack / Title"`.
/// Avoids a store-schema migration while still letting voice notes and libraries group.
public enum DocumentPack {
    /// Matches `StructuredVoiceNote.defaultPack` in LLMKit.
    public static let voiceNotes = "Voice notes"
    public static let separator = " / "

    /// Split `"Pack / Title"` into (pack, title). Titles without the separator use pack `nil`.
    public static func parse(_ documentTitle: String) -> (pack: String?, title: String) {
        guard let range = documentTitle.range(of: separator) else {
            return (nil, documentTitle)
        }
        let pack = String(documentTitle[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(documentTitle[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pack.isEmpty, !title.isEmpty else { return (nil, documentTitle) }
        return (pack, title)
    }

    public static func compose(pack: String, title: String) -> String {
        let cleanPack = pack.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPack.isEmpty else { return cleanTitle }
        return "\(cleanPack)\(separator)\(cleanTitle)"
    }

    public static func pack(of record: DocumentRecord) -> String? {
        parse(record.title).pack
    }

    public static func filter(_ records: [DocumentRecord], pack: String) -> [DocumentRecord] {
        records.filter { self.pack(of: $0) == pack }
    }

    public static func packs(in records: [DocumentRecord]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for record in records {
            if let pack = pack(of: record), seen.insert(pack).inserted {
                ordered.append(pack)
            }
        }
        return ordered.sorted()
    }
}
