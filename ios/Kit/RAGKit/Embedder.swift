import Foundation

/// Turns text into unit-length vectors.
///
/// Implementations must return L2-normalised vectors so that cosine similarity is a dot product.
public protocol Embedder: Sendable {
    /// Stable identifier. When it changes, stored vectors are re-computed.
    var identifier: String { get }
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension Embedder {
    public func embed(_ text: String) async throws -> [Float] {
        try await embed([text]).first ?? [Float](repeating: 0, count: dimension)
    }
}

/// A dependency-free embedder using feature hashing of unigrams and bigrams.
///
/// It is purely lexical (no semantic generalisation) but deterministic, fast and portable, which
/// makes it ideal for unit tests, the retrieval eval, and as a last-resort fallback on device.
public struct HashingEmbedder: Embedder {
    public let dimension: Int
    public var identifier: String { "hashing-\(dimension)-v1" }

    public init(dimension: Int = 512) {
        self.dimension = max(16, dimension)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map(vector(for:))
    }

    func vector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        let terms = Tokenizer.terms(text)
        for term in terms { add(term, weight: 1.0, into: &vector) }
        if terms.count > 1 {
            for index in 0..<(terms.count - 1) {
                add(terms[index] + "_" + terms[index + 1], weight: 0.5, into: &vector)
            }
        }
        return VectorMath.normalized(vector)
    }

    private func add(_ feature: String, weight: Float, into vector: inout [Float]) {
        let hash = StableHash.fnv1a64(feature)
        let index = Int(hash % UInt64(dimension))
        let sign: Float = (hash >> 63) == 0 ? 1 : -1
        vector[index] += sign * weight
    }
}
