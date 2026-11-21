import Foundation

/// In-memory BM25 keyword index over chunks. Fast enough for tens of thousands of chunks.
struct BM25Index {
    struct Result: Equatable {
        var id: UUID
        var score: Double
    }

    private let k1 = 1.5
    private let b = 0.75

    private var postings: [String: [UUID: Int]] = [:]
    private var lengths: [UUID: Int] = [:]
    private var terms: [UUID: [String]] = [:]
    private var documentOf: [UUID: UUID] = [:]
    private var chunksOf: [UUID: Set<UUID>] = [:]
    private var totalLength = 0

    var count: Int { lengths.count }

    mutating func add(chunkID: UUID, documentID: UUID, text: String) {
        remove(chunkID: chunkID)
        let words = Tokenizer.terms(text)
        var frequencies: [String: Int] = [:]
        for word in words { frequencies[word, default: 0] += 1 }
        for (word, frequency) in frequencies { postings[word, default: [:]][chunkID] = frequency }
        lengths[chunkID] = words.count
        terms[chunkID] = Array(frequencies.keys)
        documentOf[chunkID] = documentID
        chunksOf[documentID, default: []].insert(chunkID)
        totalLength += words.count
    }

    mutating func remove(documentID: UUID) {
        for chunkID in chunksOf[documentID] ?? [] { remove(chunkID: chunkID) }
        chunksOf[documentID] = nil
    }

    mutating func removeAll() {
        self = BM25Index()
    }

    private mutating func remove(chunkID: UUID) {
        guard let length = lengths[chunkID] else { return }
        for word in terms[chunkID] ?? [] {
            postings[word]?[chunkID] = nil
            if postings[word]?.isEmpty == true { postings[word] = nil }
        }
        totalLength -= length
        lengths[chunkID] = nil
        terms[chunkID] = nil
        if let documentID = documentOf[chunkID] { chunksOf[documentID]?.remove(chunkID) }
        documentOf[chunkID] = nil
    }

    func search(query: String, limit: Int, allowedDocuments: Set<UUID>? = nil) -> [Result] {
        let queryTerms = Set(Tokenizer.terms(query))
        guard !queryTerms.isEmpty, !lengths.isEmpty else { return [] }
        let documentCount = Double(lengths.count)
        let averageLength = max(1.0, Double(totalLength) / documentCount)

        var scores: [UUID: Double] = [:]
        for term in queryTerms {
            guard let posting = postings[term] else { continue }
            let df = Double(posting.count)
            let idf = log(1 + (documentCount - df + 0.5) / (df + 0.5))
            for (chunkID, frequency) in posting {
                if let allowedDocuments, let owner = documentOf[chunkID], !allowedDocuments.contains(owner) { continue }
                let tf = Double(frequency)
                let length = Double(lengths[chunkID] ?? 0)
                let normaliser = k1 * (1 - b + b * length / averageLength)
                scores[chunkID, default: 0] += idf * (tf * (k1 + 1)) / (tf + normaliser)
            }
        }
        return scores
            .map { Result(id: $0.key, score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id.uuidString < $1.id.uuidString }
            .prefix(limit)
            .map { $0 }
    }
}
