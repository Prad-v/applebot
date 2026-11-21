import Foundation

/// Persistence for documents, chunks and embeddings.
///
/// Searching happens in memory (see `HybridIndex`); the store is only the durable copy, loaded
/// once by `KnowledgeBase.open()`.
public protocol ChunkStore: Sendable {
    func embedderIdentifier() async throws -> String?
    func setEmbedderIdentifier(_ identifier: String) async throws

    func documents() async throws -> [DocumentRecord]
    func document(withHash hash: String) async throws -> DocumentRecord?
    func insert(document: DocumentRecord, chunks: [StoredChunk]) async throws
    func delete(documentID: UUID) async throws
    func deleteAll() async throws

    func loadAll() async throws -> [StoredChunk]
    func replaceVectors(_ vectors: [UUID: [Float]]) async throws
}

/// Volatile store for tests and previews.
public actor InMemoryChunkStore: ChunkStore {
    private var embedder: String?
    private var records: [UUID: DocumentRecord] = [:]
    private var chunks: [UUID: StoredChunk] = [:]

    public init() {}

    public func embedderIdentifier() async throws -> String? { embedder }
    public func setEmbedderIdentifier(_ identifier: String) async throws { embedder = identifier }

    public func documents() async throws -> [DocumentRecord] {
        records.values.sorted { $0.addedAt > $1.addedAt }
    }

    public func document(withHash hash: String) async throws -> DocumentRecord? {
        records.values.first { $0.contentHash == hash }
    }

    public func insert(document: DocumentRecord, chunks newChunks: [StoredChunk]) async throws {
        records[document.id] = document
        for stored in newChunks { chunks[stored.chunk.id] = stored }
    }

    public func delete(documentID: UUID) async throws {
        records[documentID] = nil
        chunks = chunks.filter { $0.value.chunk.documentID != documentID }
    }

    public func deleteAll() async throws {
        records = [:]
        chunks = [:]
    }

    public func loadAll() async throws -> [StoredChunk] {
        chunks.values.sorted {
            ($0.chunk.documentID.uuidString, $0.chunk.ordinal) < ($1.chunk.documentID.uuidString, $1.chunk.ordinal)
        }
    }

    public func replaceVectors(_ vectors: [UUID: [Float]]) async throws {
        for (id, vector) in vectors { chunks[id]?.vector = vector }
    }
}
