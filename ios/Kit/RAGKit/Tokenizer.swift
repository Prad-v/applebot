import Foundation

/// Lightweight word tokenizer used for BM25 and the hashing embedder.
public enum Tokenizer {
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "else", "of", "to", "in", "on", "at", "by",
        "for", "with", "about", "as", "into", "from", "up", "down", "is", "are", "was", "were", "be",
        "been", "being", "am", "do", "does", "did", "have", "has", "had", "it", "its", "this", "that",
        "these", "those", "i", "you", "he", "she", "we", "they", "me", "my", "your", "our", "their",
        "what", "which", "who", "whom", "how", "when", "where", "why", "can", "could", "should",
        "would", "will", "shall", "may", "might", "not", "no", "so", "than", "too", "very",
    ]

    /// Lower-cased alphanumeric words, in order, stopwords included.
    public static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Search terms: words minus stopwords, with a crude plural fold ("batteries" becomes "battery", "cells" becomes "cell").
    public static func terms(_ text: String) -> [String] {
        words(text).compactMap { word in
            guard !stopwords.contains(word) else { return nil }
            return stem(word)
        }
    }

    static func stem(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }
}

/// Deterministic, platform-independent hashing (Swift's `Hasher` is randomly seeded).
public enum StableHash {
    public static func fnv1a64(_ string: String, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 {
        var hash = seed
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// 128-bit hex fingerprint of normalised text, used to detect duplicate imports.
    public static func fingerprint(_ text: String) -> String {
        let normalised = text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let a = fnv1a64(normalised)
        let b = fnv1a64(normalised, seed: 0x9e3779b97f4a7c15)
        return String(format: "%016llx%016llx", a, b)
    }
}
