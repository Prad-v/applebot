import Foundation

/// Structured facts extracted on-device from a camera frame (Vision / optional LiDAR hint).
/// The raw image never needs to leave the device — only this text is offered to the model.
public struct SurroundingsFacts: Sendable, Equatable {
    public var classifications: [String]
    public var recognizedText: [String]
    public var humanCount: Int
    public var depthHint: String?
    public var sensorNotes: [String]
    public var capturedAt: Date

    public init(
        classifications: [String] = [],
        recognizedText: [String] = [],
        humanCount: Int = 0,
        depthHint: String? = nil,
        sensorNotes: [String] = [],
        capturedAt: Date = Date()
    ) {
        self.classifications = classifications
        self.recognizedText = recognizedText
        self.humanCount = max(0, humanCount)
        self.depthHint = depthHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sensorNotes = sensorNotes
        self.capturedAt = capturedAt
    }

    public var isEmpty: Bool {
        classifications.isEmpty && recognizedText.isEmpty && humanCount == 0 && depthHint == nil
    }
}

/// Builds prompts and a mechanical fallback narration for the Surroundings accessibility tab.
public enum SurroundingsNarrator {
    public static let safetyDisclaimer =
        "Assistive description only — not for navigation or safety-critical decisions. "
        + "Use a cane, guide dog, or trusted human help when moving. Descriptions can be wrong."

    /// Compact fact sheet for the model (token-budget friendly).
    public static func factSheet(_ facts: SurroundingsFacts) -> String {
        var lines: [String] = ["On-device scene facts:"]
        if facts.classifications.isEmpty {
            lines.append("- Scene labels: (none)")
        } else {
            lines.append("- Scene labels: " + facts.classifications.prefix(8).joined(separator: ", "))
        }
        if facts.humanCount > 0 {
            lines.append("- People detected (approximate count): \(facts.humanCount)")
        } else {
            lines.append("- People detected: none clear")
        }
        if facts.recognizedText.isEmpty {
            lines.append("- Visible text (OCR): (none)")
        } else {
            let text = facts.recognizedText.prefix(12).joined(separator: " | ")
            lines.append("- Visible text (OCR): \(TokenEstimator.truncate(text, toTokens: 180))")
        }
        if let depth = facts.depthHint {
            lines.append("- Depth / distance hint: \(depth)")
        }
        if !facts.sensorNotes.isEmpty {
            lines.append("- Sensor notes: " + facts.sensorNotes.prefix(4).joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    public static func narrationRequest(facts: SurroundingsFacts) -> LLMRequest {
        LLMRequest(
            instructions:
                "You help a blind or low-vision user understand what is in front of their iPhone camera. "
                + "Use ONLY the provided on-device scene facts. Do not invent objects that are not supported by the facts. "
                + "Speak in short spatial sentences (ahead / left / right / near / farther). "
                + "Prefer 3 to 6 short sentences. Mention uncertainty when labels are weak. "
                + "Do not give navigation directions that assume the description is perfect. "
                + "End with one short reminder that this is assistive only, not for safety-critical navigation. "
                + "No medical advice. No emoji.",
            prompt: factSheet(facts),
            temperature: 0.3,
            maximumResponseTokens: 220
        )
    }

    /// Compact live update: only what changed / what matters now. No repeated safety disclaimer.
    public static func liveNarrationRequest(
        facts: SurroundingsFacts,
        previous: SurroundingsFacts?
    ) -> LLMRequest {
        var prompt = factSheet(facts)
        if let previous {
            prompt += "\n\nPrevious facts (for contrast):\n" + factSheet(previous)
            prompt += "\nDescribe only what is new or important now in 1 or 2 short sentences."
        } else {
            prompt += "\nGive a brief first look in 1 or 2 short sentences."
        }
        return LLMRequest(
            instructions:
                "You give short live updates for a blind or low-vision user holding an iPhone. "
                + "Use ONLY the provided on-device scene facts. Do not invent objects. "
                + "1 or 2 short spatial sentences. No emoji. No medical advice. "
                + "Do not repeat a long safety disclaimer. Do not give navigation instructions.",
            prompt: prompt,
            temperature: 0.2,
            maximumResponseTokens: 80
        )
    }

    /// Stable signature for change detection (ignores timestamps and confidence noise).
    public static func signature(_ facts: SurroundingsFacts) -> String {
        let labels = facts.classifications.prefix(4).map { labelRoot($0) }.joined(separator: ",")
        let text = facts.recognizedText.prefix(4)
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
        let depth = facts.depthHint == nil ? "0" : "1"
        return "\(labels)#\(facts.humanCount)#\(text)#\(depth)"
    }

    public static func hasMeaningfulChange(from previous: SurroundingsFacts?, to next: SurroundingsFacts) -> Bool {
        guard let previous else { return !next.isEmpty }
        if next.isEmpty && previous.isEmpty { return false }
        return signature(previous) != signature(next)
    }

    /// Short spoken update when the model is unavailable during live mode.
    public static func mechanicalLiveUpdate(previous: SurroundingsFacts?, current: SurroundingsFacts) -> String {
        if current.isEmpty {
            return "Scene is unclear right now."
        }
        guard let previous else {
            return TokenEstimator.truncate(mechanicalNarration(current).replacingOccurrences(
                of: " " + safetyDisclaimer, with: ""
            ), toTokens: 60)
        }
        var parts: [String] = []
        let prevLabels = Set(previous.classifications.prefix(4).map { labelRoot($0) })
        let nextLabels = current.classifications.prefix(4).map { labelRoot($0) }
        let newLabels = nextLabels.filter { !prevLabels.contains($0) }
        if !newLabels.isEmpty {
            parts.append("Now seeing \(newLabels.prefix(2).joined(separator: ", ")).")
        }
        if current.humanCount != previous.humanCount {
            if current.humanCount == 0 {
                parts.append("People no longer clear in view.")
            } else if current.humanCount == 1 {
                parts.append("About one person in view.")
            } else {
                parts.append("About \(current.humanCount) people in view.")
            }
        }
        let prevText = Set(previous.recognizedText.prefix(4).map { $0.lowercased() })
        if let fresh = current.recognizedText.first(where: { !prevText.contains($0.lowercased()) }) {
            parts.append("New text: \(TokenEstimator.truncate(fresh, toTokens: 24)).")
        }
        if parts.isEmpty {
            if let label = nextLabels.first {
                parts.append("Still looks like \(label).")
            } else {
                parts.append("Scene updated slightly.")
            }
        }
        return parts.joined(separator: " ")
    }

    public static func normalizeLiveOutput(_ raw: String, facts: SurroundingsFacts, previous: SurroundingsFacts?) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return mechanicalLiveUpdate(previous: previous, current: facts)
        }
        return TokenEstimator.truncate(trimmed, toTokens: 70)
    }

    private static func labelRoot(_ label: String) -> String {
        let base = label.split(separator: "(").first.map(String.init) ?? label
        return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Used when the model is unavailable or returns empty text.
    public static func mechanicalNarration(_ facts: SurroundingsFacts) -> String {
        if facts.isEmpty {
            return "I could not identify clear objects in this frame. Try pointing the camera at the area you care about, with more light. "
                + safetyDisclaimer
        }
        var parts: [String] = []
        if !facts.classifications.isEmpty {
            parts.append(
                "This may be: " + facts.classifications.prefix(4).joined(separator: ", ") + "."
            )
        }
        if facts.humanCount == 1 {
            parts.append("About one person appears in view.")
        } else if facts.humanCount > 1 {
            parts.append("About \(facts.humanCount) people appear in view.")
        }
        if let firstText = facts.recognizedText.first {
            parts.append("Readable text includes: \(TokenEstimator.truncate(firstText, toTokens: 40)).")
        } else if facts.recognizedText.count > 1 {
            parts.append("Some text is visible in the scene.")
        }
        if let depth = facts.depthHint {
            parts.append(depth)
        }
        if !facts.sensorNotes.isEmpty {
            parts.append(facts.sensorNotes[0])
        }
        parts.append(safetyDisclaimer)
        return parts.joined(separator: " ")
    }

    public static func normalizeModelOutput(_ raw: String, facts: SurroundingsFacts) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return mechanicalNarration(facts) }
        if trimmed.lowercased().contains("assistive") || trimmed.lowercased().contains("not for") {
            return trimmed
        }
        return trimmed + " " + safetyDisclaimer
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
