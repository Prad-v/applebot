import Foundation

/// On-device adaptation of hybrid retrieval weights from simple thumbs feedback.
/// No cloud training — nudges vector vs keyword balance for this device/profile.
public struct RetrievalWeights: Sendable, Codable, Equatable {
    public var vectorWeight: Double
    public var keywordWeight: Double
    public var helpfulCount: Int
    public var unhelpfulCount: Int

    public static let `default` = RetrievalWeights(
        vectorWeight: 1.0, keywordWeight: 1.0, helpfulCount: 0, unhelpfulCount: 0
    )

    public init(vectorWeight: Double, keywordWeight: Double, helpfulCount: Int = 0, unhelpfulCount: Int = 0) {
        self.vectorWeight = max(0.25, min(2.5, vectorWeight))
        self.keywordWeight = max(0.25, min(2.5, keywordWeight))
        self.helpfulCount = max(0, helpfulCount)
        self.unhelpfulCount = max(0, unhelpfulCount)
    }

    /// Apply one feedback signal. `citedHadKeywordOnly` / `citedHadVectorOnly` describe the answer's sources.
    public func applying(
        helpful: Bool,
        citedHadVector: Bool,
        citedHadKeyword: Bool
    ) -> RetrievalWeights {
        var next = self
        let step = 0.08
        if helpful {
            next.helpfulCount += 1
            if citedHadVector && !citedHadKeyword {
                next.vectorWeight += step
            } else if citedHadKeyword && !citedHadVector {
                next.keywordWeight += step
            } else if citedHadVector && citedHadKeyword {
                // Balanced hit — slight pull toward current mix.
                next.vectorWeight += step * 0.25
                next.keywordWeight += step * 0.25
            }
        } else {
            next.unhelpfulCount += 1
            if citedHadVector && !citedHadKeyword {
                next.vectorWeight -= step
                next.keywordWeight += step * 0.5
            } else if citedHadKeyword && !citedHadVector {
                next.keywordWeight -= step
                next.vectorWeight += step * 0.5
            } else {
                // Ambiguous failure — slight diversify.
                next.vectorWeight -= step * 0.25
                next.keywordWeight += step * 0.25
            }
        }
        return RetrievalWeights(
            vectorWeight: next.vectorWeight,
            keywordWeight: next.keywordWeight,
            helpfulCount: next.helpfulCount,
            unhelpfulCount: next.unhelpfulCount
        )
    }
}

/// Portable helpers for turning weights into a retrieval config patch.
public enum RetrievalTuner {
    public static func config(from weights: RetrievalWeights, base: RetrievalConfigLike = .init()) -> RetrievalConfigLike {
        RetrievalConfigLike(
            candidatePool: base.candidatePool,
            rrfK: base.rrfK,
            vectorWeight: weights.vectorWeight,
            keywordWeight: weights.keywordWeight,
            mmrLambda: base.mmrLambda,
            minimumCosine: base.minimumCosine
        )
    }
}

/// Mirror of RAGKit's RetrievalConfig so LLMKit stays free of a RAGKit dependency.
public struct RetrievalConfigLike: Sendable, Equatable {
    public var candidatePool: Int
    public var rrfK: Double
    public var vectorWeight: Double
    public var keywordWeight: Double
    public var mmrLambda: Float?
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
