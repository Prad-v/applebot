import Foundation
import LLMKit

/// A unit of extracted text, optionally tagged with the page it came from.
public struct TextBlock: Sendable, Equatable {
    public var text: String
    public var page: Int?

    public init(text: String, page: Int? = nil) {
        self.text = text
        self.page = page
    }
}

/// An imported document.
public struct DocumentRecord: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var sourceName: String
    public var contentHash: String
    public var addedAt: Date
    public var chunkCount: Int

    public init(
        id: UUID = UUID(), title: String, sourceName: String,
        contentHash: String, addedAt: Date = Date(), chunkCount: Int
    ) {
        self.id = id
        self.title = title
        self.sourceName = sourceName
        self.contentHash = contentHash
        self.addedAt = addedAt
        self.chunkCount = chunkCount
    }
}

/// A retrievable passage of a document.
public struct Chunk: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var documentID: UUID
    public var ordinal: Int
    public var text: String
    public var page: Int?
    public var heading: String?

    public init(
        id: UUID = UUID(), documentID: UUID, ordinal: Int,
        text: String, page: Int? = nil, heading: String? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.ordinal = ordinal
        self.text = text
        self.page = page
        self.heading = heading
    }

    /// Text used for embedding and keyword search: the heading gives each chunk its topic.
    public var searchText: String {
        if let heading, !heading.isEmpty { return heading + "\n" + text }
        return text
    }

    /// Human-readable location, e.g. "Installation · p. 3".
    public var locationLabel: String? {
        var parts: [String] = []
        if let heading, !heading.isEmpty { parts.append(heading) }
        if let page { parts.append("p. \(page)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A chunk with its embedding, as persisted.
public struct StoredChunk: Sendable, Equatable {
    public var chunk: Chunk
    public var vector: [Float]

    public init(chunk: Chunk, vector: [Float]) {
        self.chunk = chunk
        self.vector = vector
    }
}

/// One retrieval result.
public struct SearchHit: Sendable, Equatable, Identifiable {
    public var chunk: Chunk
    public var documentTitle: String
    /// Fused (RRF) relevance score; only meaningful relative to other hits of the same query.
    public var score: Double
    /// Cosine similarity of the chunk to the query (embedding space).
    public var cosine: Float
    /// 1-based ranks in the individual rankers, nil when the ranker did not return the chunk.
    public var vectorRank: Int?
    public var keywordRank: Int?

    public var id: UUID { chunk.id }

    public var snippet: ContextSnippet {
        ContextSnippet(
            id: chunk.id.uuidString,
            title: documentTitle,
            location: chunk.locationLabel,
            text: chunk.text
        )
    }
}

public enum IngestOutcome: Sendable, Equatable {
    case added(DocumentRecord)
    /// The same content was already imported.
    case duplicate(DocumentRecord)
}

public enum RAGError: Error, Sendable, Equatable, LocalizedError {
    case emptyDocument
    case unsupportedFileType(String)
    case extractionFailed(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument: return "No readable text was found in this document."
        case .unsupportedFileType(let ext): return "Files of type \"\(ext)\" are not supported yet."
        case .extractionFailed(let why): return "Could not read the document: \(why)"
        case .storage(let why): return "Storage error: \(why)"
        }
    }
}
