import Foundation
import LLMKit

/// Document library packs: first-class `DocumentRecord.pack`, with legacy `"Pack / Title"` fallback.
public enum DocumentPack {
    public static let voiceNotes = "Voice notes"
    public static let separator = " / "
    public static let unfiledLabel = "Unfiled"

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

    public static func compose(pack: String?, title: String) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pack, !pack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return cleanTitle
        }
        return "\(pack.trimmingCharacters(in: .whitespacesAndNewlines))\(separator)\(cleanTitle)"
    }

    public static func pack(of record: DocumentRecord) -> String? {
        if let pack = record.pack, !pack.isEmpty { return pack }
        return parse(record.title).pack
    }

    public static func filter(_ records: [DocumentRecord], pack: String?) -> [DocumentRecord] {
        switch pack {
        case nil:
            return records
        case "":
            return records.filter { self.pack(of: $0) == nil }
        case let name?:
            return records.filter { self.pack(of: $0) == name }
        }
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

    public static func forProfile(_ records: [DocumentRecord], profileID: UUID?) -> [DocumentRecord] {
        guard let profileID else { return records }
        return records.filter { $0.profileID == nil || $0.profileID == profileID }
    }
}

/// Converts LLMKit retrieval tuner weights into RAGKit config.
public extension RetrievalConfig {
    init(like: RetrievalConfigLike) {
        self.init(
            candidatePool: like.candidatePool,
            rrfK: like.rrfK,
            vectorWeight: like.vectorWeight,
            keywordWeight: like.keywordWeight,
            mmrLambda: like.mmrLambda,
            minimumCosine: like.minimumCosine
        )
    }

    init(weights: RetrievalWeights) {
        self.init(vectorWeight: weights.vectorWeight, keywordWeight: weights.keywordWeight)
    }
}
