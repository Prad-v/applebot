#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// Apple's built-in static sentence embedding. No downloads; works offline immediately.
public final class NLSentenceEmbedder: Embedder, @unchecked Sendable {
    private let embedding: NLEmbedding
    private let language: NLLanguage
    private let lock = NSLock()

    public let dimension: Int
    public var identifier: String { "nl-sentence-\(language.rawValue)-\(dimension)" }

    public init?(language: NLLanguage = .english) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        self.embedding = embedding
        self.language = language
        self.dimension = embedding.dimension
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        embedSynchronously(texts)
    }

    private func embedSynchronously(_ texts: [String]) -> [[Float]] {
        lock.withLock {
            texts.map { text in
                let limited = String(text.prefix(2_000))
                guard let vector = embedding.vector(for: limited) else {
                    return [Float](repeating: 0, count: dimension)
                }
                return VectorMath.normalizedFloats(from: vector)
            }
        }
    }
}

/// Contextual (transformer-based) embeddings from `NLContextualEmbedding`, mean-pooled per text.
///
/// Higher quality than `NLSentenceEmbedder`, but the model assets may need a one-time download
/// (`requestAssets()`) while online. Check `hasAvailableAssets` before relying on it offline.
public final class NLContextualEmbedder: Embedder, @unchecked Sendable {
    private let model: NLContextualEmbedding
    private let language: NLLanguage
    private let lock = NSLock()
    private var loaded = false

    public let dimension: Int
    public var identifier: String { "nl-contextual-\(model.modelIdentifier)-\(dimension)" }

    public init?(language: NLLanguage = .english) {
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        self.model = model
        self.language = language
        self.dimension = model.dimension
    }

    public var hasAvailableAssets: Bool { model.hasAvailableAssets }

    /// Download the model assets if they are missing. Requires a network connection once.
    public func requestAssets() async throws {
        if model.hasAvailableAssets { return }
        let result = try await model.requestAssets()
        guard result == .available else {
            throw RAGError.extractionFailed("embedding assets are not available")
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try embedSynchronously(texts)
    }

    private func embedSynchronously(_ texts: [String]) throws -> [[Float]] {
        try lock.withLock {
            if !loaded {
                try model.load()
                loaded = true
            }
            return try texts.map { text in
                let limited = String(text.prefix(2_000))
                let result = try model.embeddingResult(for: limited, language: language)
                var sum = [Double](repeating: 0, count: dimension)
                var count = 0
                result.enumerateTokenVectors(in: limited.startIndex..<limited.endIndex) { vector, _ in
                    if vector.count == sum.count {
                        for index in vector.indices { sum[index] += vector[index] }
                        count += 1
                    }
                    return true
                }
                guard count > 0 else { return [Float](repeating: 0, count: dimension) }
                return VectorMath.normalizedFloats(from: sum.map { $0 / Double(count) })
            }
        }
    }
}

/// Chooses the best embedder that works offline right now.
public enum EmbedderFactory {
    /// Contextual embeddings when their assets are already on the device, else the built-in
    /// sentence embedding, else the portable hashing embedder.
    public static func preferred(language: NLLanguage = .english) -> any Embedder {
        if let contextual = NLContextualEmbedder(language: language), contextual.hasAvailableAssets {
            return contextual
        }
        if let sentence = NLSentenceEmbedder(language: language) { return sentence }
        return HashingEmbedder()
    }
}
#endif
