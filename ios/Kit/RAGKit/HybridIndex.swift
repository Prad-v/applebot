import Foundation

public struct RetrievalConfig: Sendable, Equatable {
    /// Candidates pulled from each ranker before fusion.
    public var candidatePool: Int
    /// Reciprocal Rank Fusion constant.
    public var rrfK: Double
    public var vectorWeight: Double
    public var keywordWeight: Double
    /// MMR trade-off between relevance (1.0) and diversity (0.0). Nil disables MMR.
    public var mmrLambda: Float?
    /// Drop vector-only hits whose cosine is below this. Nil keeps everything.
    public var minimumCosine: Float?

    public init(
        candidatePool: Int = 20, rrfK: Double = 60,
        vectorWeight: Double = 1.0, keywordWeight: Double = 1.0,
        mmrLambda: Float? = 0.75, minimumCosine: Float? = nil
    ) {
        self.candidatePool = candidatePool
        self.rrfK = rrfK
        self.vectorWeight = vectorWeight
        self.keywordWeight = keywordWeight
        self.mmrLambda = mmrLambda
        self.minimumCosine = minimumCosine
    }
}

/// Combines vector and BM25 rankings with Reciprocal Rank Fusion, optionally followed by MMR.
struct HybridIndex {
    struct Candidate: Equatable {
        var id: UUID
        var score: Double
        var cosine: Float
        var vectorRank: Int?
        var keywordRank: Int?
    }

    private var vectors: VectorIndex
    private var keywords = BM25Index()

    init(dimension: Int) {
        vectors = VectorIndex(dimension: dimension)
    }

    var count: Int { vectors.count }

    mutating func add(_ stored: StoredChunk) {
        vectors.add(id: stored.chunk.id, documentID: stored.chunk.documentID, vector: stored.vector)
        keywords.add(chunkID: stored.chunk.id, documentID: stored.chunk.documentID, text: stored.chunk.searchText)
    }

    mutating func remove(documentID: UUID) {
        vectors.remove(documentID: documentID)
        keywords.remove(documentID: documentID)
    }

    mutating func removeAll() {
        vectors.removeAll()
        keywords.removeAll()
    }

    func search(
        query: String, queryVector: [Float], limit: Int,
        allowedDocuments: Set<UUID>?, config: RetrievalConfig
    ) -> [Candidate] {
        let pool = max(limit, config.candidatePool)
        let vectorResults = vectors.search(query: queryVector, limit: pool, allowedDocuments: allowedDocuments)
        let keywordResults = keywords.search(query: query, limit: pool, allowedDocuments: allowedDocuments)

        var cosines: [UUID: Float] = [:]
        var vectorRanks: [UUID: Int] = [:]
        var keywordRanks: [UUID: Int] = [:]
        var fused: [UUID: Double] = [:]

        for (offset, result) in vectorResults.enumerated() {
            cosines[result.id] = result.cosine
            vectorRanks[result.id] = offset + 1
            fused[result.id, default: 0] += config.vectorWeight / (config.rrfK + Double(offset + 1))
        }
        for (offset, result) in keywordResults.enumerated() {
            keywordRanks[result.id] = offset + 1
            fused[result.id, default: 0] += config.keywordWeight / (config.rrfK + Double(offset + 1))
        }

        var candidates = fused.map { id, score in
            Candidate(
                id: id, score: score,
                cosine: cosines[id] ?? (vectors.vector(for: id).map { VectorMath.dot($0, queryVector) } ?? 0),
                vectorRank: vectorRanks[id], keywordRank: keywordRanks[id]
            )
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id.uuidString < $1.id.uuidString }

        if let minimum = config.minimumCosine {
            candidates = candidates.filter { $0.keywordRank != nil || $0.cosine >= minimum }
        }

        guard let lambda = config.mmrLambda, candidates.count > limit else {
            return Array(candidates.prefix(limit))
        }
        return mmr(candidates: candidates, limit: limit, lambda: lambda)
    }

    /// Maximal Marginal Relevance: greedily pick candidates that are relevant yet not near-duplicates.
    private func mmr(candidates: [Candidate], limit: Int, lambda: Float) -> [Candidate] {
        let maxScore = candidates.first?.score ?? 1
        var remaining = candidates
        var selected: [Candidate] = []
        var selectedVectors: [[Float]] = []

        while selected.count < limit, !remaining.isEmpty {
            var bestIndex = 0
            var bestValue = -Float.greatestFiniteMagnitude
            for (index, candidate) in remaining.enumerated() {
                let relevance = Float(candidate.score / maxScore)
                let redundancy: Float = {
                    guard let vector = vectors.vector(for: candidate.id) else { return 0 }
                    return selectedVectors.map { VectorMath.dot(vector, $0) }.max() ?? 0
                }()
                let value = lambda * relevance - (1 - lambda) * redundancy
                if value > bestValue { bestValue = value; bestIndex = index }
            }
            let pick = remaining.remove(at: bestIndex)
            selected.append(pick)
            if let vector = vectors.vector(for: pick.id) { selectedVectors.append(vector) }
        }
        return selected
    }
}
