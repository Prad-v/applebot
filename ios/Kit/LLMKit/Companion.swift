import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// Emotional chat support: a conversation tone, an on-device emotion reading for each user message,
// and the instruction text that turns both into a more empathetic reply. Everything here is local.

/// How Applebot talks. `neutral` is the original concise assistant; the others add warmth.
public enum ChatTone: String, Sendable, Codable, CaseIterable, Identifiable {
    case neutral
    case warm
    case coach

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .neutral: return "Neutral"
        case .warm: return "Warm companion"
        case .coach: return "Supportive coach"
        }
    }

    public var summary: String {
        switch self {
        case .neutral: return "Concise and factual."
        case .warm: return "Kind and attentive. Listens first, like a thoughtful friend."
        case .coach: return "Encouraging and practical. Helps you take a small next step."
        }
    }

    /// Whether replies adapt to the user's detected emotion.
    public var isEmotionAware: Bool { self != .neutral }

    /// The persona instructions for this tone.
    public var persona: String {
        switch self {
        case .neutral:
            return PromptBuilder.defaultPersona
        case .warm:
            return "You are Applebot, a warm and caring companion running privately on the user's iPhone. "
                + "Talk like a thoughtful friend: natural, kind and unhurried. "
                + "When the user shares a feeling, acknowledge it and reflect back what you heard before offering any advice. "
                + "Ask at most one gentle follow-up question. "
                + "Use plain sentences, not bullet lists or headings, and do not lecture. "
                + "Never claim to be a therapist and never diagnose. "
                + "If the user mentions harming themselves or being in danger, respond with care and encourage them to contact local emergency services or a crisis line right away."
        case .coach:
            return "You are Applebot, a supportive coach running privately on the user's iPhone. "
                + "Be encouraging, honest and practical. "
                + "Acknowledge how the user feels in one sentence, then help them find one small, concrete next step. "
                + "Ask at most one question. Keep replies short and in plain sentences. "
                + "Never claim to be a therapist and never diagnose. "
                + "If the user mentions harming themselves or being in danger, respond with care and encourage them to contact local emergency services or a crisis line right away."
        }
    }
}

/// The main feeling detected in a message.
public enum Emotion: String, Sendable, Codable, CaseIterable {
    case neutral
    case joy
    case sadness
    case anxiety
    case anger

    /// Feelings where the user probably wants support rather than information.
    public var isDistress: Bool {
        switch self {
        case .sadness, .anxiety, .anger: return true
        case .neutral, .joy: return false
        }
    }
}

/// An emotion plus how strongly it came through (1 = hint, 5 = very strong).
public struct EmotionReading: Sendable, Codable, Equatable {
    public static let neutral = EmotionReading(emotion: .neutral, intensity: 0)

    public var emotion: Emotion
    public var intensity: Int

    public init(emotion: Emotion, intensity: Int) {
        self.emotion = emotion
        self.intensity = emotion == .neutral ? 0 : min(max(intensity, 1), 5)
    }

    public var isEmotional: Bool { emotion != .neutral }

    /// True when the user is clearly struggling. Answering from documents would feel cold here, so
    /// the pipeline skips retrieval and just talks to them.
    public var needsSupport: Bool { emotion.isDistress && intensity >= 3 }

    /// Extra instructions that match the reply to the user's mood. Empty for neutral readings.
    public var guidance: String? {
        guard isEmotional else { return nil }
        let strong = intensity >= 4
        switch emotion {
        case .neutral:
            return nil
        case .sadness:
            return "The user seems sad. Be gentle and validating; do not rush to fix things or look on the bright side."
                + (strong ? " Keep the reply short and soft." : "")
        case .anxiety:
            return "The user seems anxious or stressed. Be calm and reassuring, and help them slow down."
                + (strong ? " Keep the reply short and suggest one small step or a slow breath." : "")
        case .anger:
            return "The user seems frustrated or angry. Stay calm, validate the frustration, and do not argue or lecture."
                + (strong ? " Keep the reply short." : "")
        case .joy:
            return "The user seems happy. Share their excitement and celebrate with them."
        }
    }
}

/// Reads the emotion in a piece of text.
public protocol EmotionDetecting: Sendable {
    func read(_ text: String) -> EmotionReading
}

/// Portable keyword-based detector (runs on Linux in tests). It is deliberately simple, cheap and
/// predictable: it counts emotion words, handles simple negation and boosts intensity for
/// emphasis. On Apple platforms prefer `SentimentEmotionDetector`, which adds Apple's sentiment
/// model as a fallback.
public struct LexiconEmotionDetector: EmotionDetecting {
    public init() {}

    private static let lexicon: [Emotion: Set<String>] = [
        .sadness: [
            "sad", "unhappy", "depressed", "depressing", "crying", "cried", "cry", "heartbroken", "grief",
            "grieving", "hopeless", "lonely", "empty", "devastated", "miserable", "hurt", "hurting",
            "worthless", "died", "breakup", "tearful", "numb",
        ],
        .anxiety: [
            "anxious", "anxiety", "worried", "worry", "worrying", "nervous", "scared", "afraid", "panic",
            "panicking", "overwhelmed", "stressed", "stress", "terrified", "dread", "uneasy", "tense",
            "burnout", "insomnia",
        ],
        .anger: [
            "angry", "furious", "mad", "pissed", "hate", "annoyed", "frustrated", "frustrating", "irritated",
            "livid", "resent", "outraged", "fuming", "unfair",
        ],
        .joy: [
            "happy", "excited", "thrilled", "proud", "grateful", "amazing", "wonderful", "delighted",
            "celebrate", "celebrating", "glad", "relieved",
        ],
    ]

    private static let phrases: [Emotion: [String]] = [
        .sadness: ["passed away", "broke up", "can't stop crying", "feel like giving up", "no one cares", "miss him", "miss her"],
        .anxiety: ["can't sleep", "cant sleep", "can't breathe", "freaking out", "on edge"],
        .anger: ["fed up", "sick of", "so unfair", "can't stand"],
        .joy: ["good news", "got the job", "so glad", "best day"],
    ]

    private static let negations: Set<String> = ["not", "never", "no", "isn't", "isnt", "aren't", "arent", "wasn't", "wasnt", "don't", "dont", "barely"]
    private static let intensifiers: Set<String> = ["so", "very", "really", "extremely", "completely", "totally", "constantly", "always", "absolutely", "utterly"]
    /// Order used to break ties.
    private static let priority: [Emotion] = [.sadness, .anxiety, .anger, .joy]

    public func read(_ text: String) -> EmotionReading {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let tokens = lowered
            .split(whereSeparator: { !($0.isLetter || $0 == "'") })
            .map(String.init)
        guard !tokens.isEmpty else { return .neutral }

        var scores: [Emotion: Int] = [:]

        for (index, token) in tokens.enumerated() {
            for emotion in Self.priority where Self.lexicon[emotion]?.contains(token) == true {
                let negated = index > 0 && Self.negations.contains(tokens[index - 1])
                if negated {
                    // "not happy" is a mild sign of sadness; other negated words ("not worried") cancel out.
                    if emotion == .joy { scores[.sadness, default: 0] += 1 }
                    continue
                }
                scores[emotion, default: 0] += 2
                if index > 0, Self.intensifiers.contains(tokens[index - 1]) { scores[emotion, default: 0] += 1 }
            }
        }

        let padded = " " + tokens.joined(separator: " ") + " "
        for emotion in Self.priority {
            for phrase in Self.phrases[emotion] ?? [] where padded.contains(" \(phrase) ") {
                scores[emotion, default: 0] += 3
            }
        }

        guard let best = Self.priority.max(by: { (scores[$0] ?? 0) < (scores[$1] ?? 0) }),
              let score = scores[best], score > 0 else { return .neutral }

        var intensity = 1 + (score + 1) / 2          // 2 -> 2, 3 -> 3, 4 -> 3, 5 -> 4, 6+ -> 4/5
        if text.contains("!!") || text.contains("??") { intensity += 1 }
        let letters = text.filter(\.isLetter)
        if letters.count >= 8, letters.allSatisfy({ !$0.isLowercase }) { intensity += 1 } // shouting
        return EmotionReading(emotion: best, intensity: intensity)
    }
}

#if canImport(NaturalLanguage)
/// Lexicon detector backed by Apple's on-device sentiment score for messages with no emotion words
/// ("Everything feels pointless lately"). Runs entirely on the device.
public struct SentimentEmotionDetector: EmotionDetecting {
    private let base = LexiconEmotionDetector()
    /// Sentiment scores range from -1 (very negative) to 1 (very positive).
    public var negativeThreshold: Double

    public init(negativeThreshold: Double = -0.6) {
        self.negativeThreshold = negativeThreshold
    }

    public func read(_ text: String) -> EmotionReading {
        let reading = base.read(text)
        guard !reading.isEmotional else { return reading }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        guard let score = tag.flatMap({ Double($0.rawValue) }), score <= negativeThreshold else { return reading }
        return EmotionReading(emotion: .sadness, intensity: score <= -0.9 ? 3 : 2)
    }
}
#endif
