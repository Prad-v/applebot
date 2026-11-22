import Foundation
import LLMKit

/// The private document library: ingest, persist, and search.
///
/// All state is on-device. Search runs in memory over vectors loaded from the `ChunkStore`.
public actor KnowledgeBase {
    private let store: ChunkStore
    private let embedder: Embedder
    private let chunker: Chunker
    private let batchSize: Int

    private var index: HybridIndex
    private var chunks: [UUID: Chunk] = [:]
    private var records: [UUID: DocumentRecord] = [:]
    private var isOpen = false
    /// Active family profile for new ingestions (nil = legacy shared).
    public var ingestProfileID: UUID?

    public init(store: ChunkStore, embedder: Embedder, chunker: Chunker = Chunker(), batchSize: Int = 16) {
        self.store = store
        self.embedder = embedder
        self.chunker = chunker
        self.batchSize = max(1, batchSize)
        self.index = HybridIndex(dimension: embedder.dimension)
    }

    public func setIngestProfileID(_ id: UUID?) {
        ingestProfileID = id
    }

    // MARK: Lifecycle

    /// Load persisted data into memory. If the embedder changed since the data was written, all
    /// vectors are recomputed (progress is reported 0...1).
    public func open(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !isOpen else { return }
        var stored = try await store.loadAll()

        let previous = try await store.embedderIdentifier()
        let needsReindex = (previous != nil && previous != embedder.identifier)
            || stored.contains { $0.vector.count != embedder.dimension }
        if needsReindex, !stored.isEmpty {
            stored = try await reembed(stored, progress: progress)
        }
        try await store.setEmbedderIdentifier(embedder.identifier)

        index = HybridIndex(dimension: embedder.dimension)
        chunks = [:]
        for item in stored {
            index.add(item)
            chunks[item.chunk.id] = item.chunk
        }
        records = Dictionary(uniqueKeysWithValues: try await store.documents().map { ($0.id, $0) })
        isOpen = true
    }

    private func reembed(_ stored: [StoredChunk], progress: (@Sendable (Double) -> Void)?) async throws -> [StoredChunk] {
        var updated = stored
        var replacement: [UUID: [Float]] = [:]
        var done = 0
        for start in stride(from: 0, to: stored.count, by: batchSize) {
            let range = start..<min(start + batchSize, stored.count)
            let vectors = try await embedder.embed(stored[range].map { $0.chunk.searchText })
            for (offset, vector) in vectors.enumerated() {
                updated[start + offset].vector = vector
                replacement[stored[start + offset].chunk.id] = vector
            }
            done += range.count
            progress?(Double(done) / Double(stored.count))
        }
        try await store.replaceVectors(replacement)
        return updated
    }

    // MARK: Documents

    public func documents() -> [DocumentRecord] {
        records.values.sorted { $0.addedAt > $1.addedAt }
    }

    public var chunkCount: Int { index.count }

    /// Chunk, embed and persist a document. Re-importing identical content is a no-op.
    @discardableResult
    public func ingest(
        title: String,
        sourceName: String? = nil,
        blocks: [TextBlock],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> IngestOutcome {
        try await openIfNeeded()
        let fullText = blocks.map(\.text).joined(separator: "\n\n")
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RAGError.emptyDocument }

        let hash = StableHash.fingerprint(fullText)
        if let existing = try await store.document(withHash: hash) { return .duplicate(existing) }

        let drafts = chunker.chunk(blocks: blocks)
        guard !drafts.isEmpty else { throw RAGError.emptyDocument }

        let documentID = UUID()
        let newChunks = drafts.enumerated().map { ordinal, draft in
            Chunk(documentID: documentID, ordinal: ordinal, text: draft.text, page: draft.page, heading: draft.heading)
        }

        var stored: [StoredChunk] = []
        for start in stride(from: 0, to: newChunks.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(newChunks[start..<min(start + batchSize, newChunks.count)])
            let vectors = try await embedder.embed(batch.map(\.searchText))
            for (chunk, vector) in zip(batch, vectors) { stored.append(StoredChunk(chunk: chunk, vector: vector)) }
            progress?(Double(stored.count) / Double(newChunks.count))
        }

        let record = DocumentRecord(
            id: documentID, title: title, sourceName: sourceName ?? title,
            contentHash: hash, chunkCount: newChunks.count,
            pack: DocumentPack.parse(title).pack, profileID: ingestProfileID
        )
        try await store.insert(document: record, chunks: stored)
        for item in stored {
            index.add(item)
            chunks[item.chunk.id] = item.chunk
        }
        records[record.id] = record
        return .added(record)
    }

    @discardableResult
    public func ingest(title: String, text: String) async throws -> IngestOutcome {
        try await ingest(title: title, blocks: [TextBlock(text: text)])
    }

    public func remove(documentID: UUID) async throws {
        try await store.delete(documentID: documentID)
        index.remove(documentID: documentID)
        chunks = chunks.filter { $0.value.documentID != documentID }
        records[documentID] = nil
    }

    /// Move a document into a pack (or unfiled) without re-embedding.
    @discardableResult
    public func setPack(documentID: UUID, pack: String?) async throws -> DocumentRecord? {
        try await openIfNeeded()
        guard var record = records[documentID] else { return nil }
        let bareTitle = DocumentPack.parse(record.title).title
        let cleaned = pack?.trimmingCharacters(in: .whitespacesAndNewlines)
        record.pack = (cleaned?.isEmpty == false) ? cleaned : nil
        record.title = DocumentPack.compose(pack: record.pack, title: bareTitle)
        try await store.updateDocument(record)
        records[documentID] = record
        return record
    }

    /// Full document text for vault export (chunks joined in order).
    public func exportText(documentID: UUID) -> String? {
        let ordered = chunks.values
            .filter { $0.documentID == documentID }
            .sorted { $0.ordinal < $1.ordinal }
        guard !ordered.isEmpty else { return nil }
        return ordered.map(\.text).joined(separator: "\n\n")
    }

    public func documents(forProfile profileID: UUID?) -> [DocumentRecord] {
        DocumentPack.forProfile(documents(), profileID: profileID)
    }

    public func removeAll() async throws {
        try await store.deleteAll()
        index.removeAll()
        chunks = [:]
        records = [:]
    }

    // MARK: Search

    /// Hybrid (vector + keyword) search. `scope` restricts results to the given documents.
    public func search(
        query: String,
        limit: Int = 4,
        scope: Set<UUID>? = nil,
        config: RetrievalConfig = RetrievalConfig()
    ) async throws -> [SearchHit] {
        try await openIfNeeded()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, index.count > 0 else { return [] }
        if let scope, scope.isEmpty { return [] }

        let queryVector = try await embedder.embed(trimmed)
        let candidates = index.search(
            query: trimmed, queryVector: queryVector, limit: limit,
            allowedDocuments: scope, config: config
        )
        return candidates.compactMap { candidate in
            guard let chunk = chunks[candidate.id], let record = records[chunk.documentID] else { return nil }
            return SearchHit(
                chunk: chunk, documentTitle: record.title, score: candidate.score, cosine: candidate.cosine,
                vectorRank: candidate.vectorRank, keywordRank: candidate.keywordRank
            )
        }
    }

    /// Retrieval hook for `ChatPipeline`.
    public nonisolated func retriever(
        limit: Int = 4, scope: Set<UUID>? = nil, config: RetrievalConfig = RetrievalConfig()
    ) -> SnippetRetriever {
        { query in
            try await self.search(query: query, limit: limit, scope: scope, config: config).map(\.snippet)
        }
    }

    private func openIfNeeded() async throws {
        if !isOpen { try await open() }
    }
}
