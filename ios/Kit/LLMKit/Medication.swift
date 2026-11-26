import Foundation

/// Where an Applebot-only medication entry came from.
public enum MedicationSource: String, Sendable, Codable, CaseIterable {
    case manual
    case photoOCR
    case healthRecords

    public var displayName: String {
        switch self {
        case .manual: return "Entered manually"
        case .photoOCR: return "From photo"
        case .healthRecords: return "From Health Records"
        }
    }
}

/// Portable medication fact stored by Applebot (never written to Apple Health).
public struct MedicationInfo: Sendable, Equatable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var dose: String
    public var frequency: String
    public var notes: String
    public var source: MedicationSource
    public var ocrRawText: String?
    public var userConfirmed: Bool
    public var updatedAt: Date
    /// Local notification reminders (Applebot-only; not written to Apple Health).
    public var remindersEnabled: Bool
    /// Daily reminder times as `HH:mm` (24h, local calendar).
    public var reminderTimes: [String]
    /// Last time the user tapped “Taken” in Applebot.
    public var lastTakenAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        dose: String = "",
        frequency: String = "",
        notes: String = "",
        source: MedicationSource = .manual,
        ocrRawText: String? = nil,
        userConfirmed: Bool = true,
        updatedAt: Date = Date(),
        remindersEnabled: Bool = false,
        reminderTimes: [String] = [],
        lastTakenAt: Date? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dose = dose.trimmingCharacters(in: .whitespacesAndNewlines)
        self.frequency = frequency.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.ocrRawText = ocrRawText
        self.userConfirmed = userConfirmed
        self.updatedAt = updatedAt
        self.remindersEnabled = remindersEnabled
        self.reminderTimes = Self.normalizeTimes(reminderTimes)
        self.lastTakenAt = lastTakenAt
    }

    public var displayLine: String {
        var parts = [name]
        if !dose.isEmpty { parts.append(dose) }
        if !frequency.isEmpty { parts.append(frequency) }
        return parts.joined(separator: " · ")
    }

    public func takenToday(calendar: Calendar = .current, now: Date = Date()) -> Bool {
        guard let lastTakenAt else { return false }
        return calendar.isDate(lastTakenAt, inSameDayAs: now)
    }

    /// Match a spoken / typed name to a saved medication (exact, then contains).
    public static func bestMatch(named raw: String, in medications: [MedicationInfo]) -> MedicationInfo? {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let exact = medications.first(where: {
            $0.name.localizedCaseInsensitiveCompare(needle) == .orderedSame
        }) {
            return exact
        }
        return medications.first(where: {
            $0.name.localizedCaseInsensitiveContains(needle) || needle.localizedCaseInsensitiveContains($0.name)
        })
    }

    public static func normalizeTimes(_ times: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in times {
            guard let normalized = normalizeTime(raw), seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered.sorted()
    }

    public static func normalizeTime(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }
}

/// One day in a multi-day wellness trend.
public struct WellnessDayPoint: Sendable, Equatable, Identifiable {
    public var id: Date { day }
    public var day: Date
    public var score: Int
    public var steps: Double?
    public var sleepHours: Double?
    public var workoutCount: Int

    public init(
        day: Date,
        score: Int,
        steps: Double? = nil,
        sleepHours: Double? = nil,
        workoutCount: Int = 0
    ) {
        self.day = day
        self.score = score
        self.steps = steps
        self.sleepHours = sleepHours
        self.workoutCount = max(0, workoutCount)
    }
}

/// Compact medication + wellness block for the chat instruction slot.
public enum HealthContextBudget {
    public static let maxTokens = 120

    public static let disclaimer =
        "Applebot is not a medical device and does not give medical advice. "
        + "Medication notes are general information — verify with a clinician or pharmacist."

    /// Renders confirmed meds (and optional score/summary) for `PromptBuilder` memories.
    public static func render(
        medications: [MedicationInfo],
        score: WellnessScore? = nil,
        activityLine: String? = nil,
        maxTokens: Int = maxTokens
    ) -> String? {
        let confirmed = medications.filter(\.userConfirmed).filter { !$0.name.isEmpty }
        var lines: [String] = ["Health context (on this iPhone only):"]
        if let score {
            lines.append("- \(score.summaryLine)")
        }
        if let activityLine, !activityLine.isEmpty {
            lines.append("- \(activityLine)")
        }
        if confirmed.isEmpty {
            if lines.count == 1 { return nil }
        } else {
            lines.append("- Medications (user-confirmed, Applebot-only):")
            for med in confirmed.prefix(8) {
                lines.append("  • \(med.displayLine)")
            }
        }
        lines.append("- \(disclaimer)")
        return TokenEstimator.truncate(lines.joined(separator: "\n"), toTokens: maxTokens)
    }
}

/// Draft parsed from a label photo / OCR text before the user confirms.
public struct MedicationDraft: Sendable, Equatable, Identifiable {
    public var id: String { ocrRawText + "\n" + name + "\n" + dose }
    public var name: String
    public var dose: String
    public var frequency: String
    public var notes: String
    public var ocrRawText: String

    public init(
        name: String = "",
        dose: String = "",
        frequency: String = "",
        notes: String = "",
        ocrRawText: String = ""
    ) {
        self.name = name
        self.dose = dose
        self.frequency = frequency
        self.notes = notes
        self.ocrRawText = ocrRawText
    }

    public var asInfo: MedicationInfo {
        MedicationInfo(
            name: name,
            dose: dose,
            frequency: frequency,
            notes: notes,
            source: .photoOCR,
            ocrRawText: ocrRawText.isEmpty ? nil : ocrRawText,
            userConfirmed: true
        )
    }
}

/// Heuristic + optional model polish for medication label OCR.
public struct MedicationParser: Sendable {
    public init() {}

    public static func draft(fromOCR text: String) -> MedicationDraft {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return MedicationDraft(ocrRawText: text)
        }

        let lines = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var name = lines.first.map { String($0) } ?? ""
        var dose = ""
        var frequency = ""

        let freqHints = ["once", "twice", "daily", "bid", "tid", "qid", "every", "morning", "night", "bedtime", "as needed", "prn"]

        for line in lines {
            let lowered = line.lowercased()
            if dose.isEmpty, let found = extractDose(from: line) {
                dose = found
            }
            if frequency.isEmpty, freqHints.contains(where: { lowered.contains($0) }) {
                frequency = line
            }
            // Prefer a line that looks like a drug name (not pharmacy boilerplate).
            if name.count < 3 || name.lowercased().contains("pharmacy") || name.lowercased().contains("rx ") {
                if line.count >= 3, line.count <= 60, !line.contains("http") {
                    name = line
                }
            }
        }

        return MedicationDraft(
            name: String(name.prefix(80)),
            dose: String(dose.prefix(40)),
            frequency: String(frequency.prefix(80)),
            notes: "",
            ocrRawText: cleaned
        )
    }

    public func polishRequest(ocrText: String) -> LLMRequest {
        LLMRequest(
            instructions: "Extract medication details from OCR text on a pill bottle or prescription label. "
                + "Output exactly four lines:\n"
                + "NAME: <medication name>\n"
                + "DOSE: <strength if present>\n"
                + "FREQUENCY: <how often if present>\n"
                + "NOTES: <other useful label facts, or none>\n"
                + "Do not invent a drug name that is not supported by the text. "
                + "Do not give medical advice.",
            prompt: TokenEstimator.truncate(ocrText, toTokens: 500)
        )
    }

    private static func extractDose(from line: String) -> String? {
        let units = ["mg", "mcg", "ug", "µg", "g", "ml", "iu"]
        let tokens = line.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        for (index, token) in tokens.enumerated() {
            let t = String(token)
            let lower = t.lowercased()
            for unit in units {
                if lower.hasSuffix(unit), lower.count > unit.count {
                    let prefix = lower.dropLast(unit.count)
                    if prefix.contains(where: \.isNumber) { return t }
                }
                if lower == unit, index > 0 {
                    let prev = String(tokens[index - 1])
                    if prev.contains(where: \.isNumber) { return "\(prev) \(t)" }
                }
            }
        }
        return nil
    }

    public static func parsePolished(_ raw: String, fallback ocrText: String) -> MedicationDraft {
        var draft = draft(fromOCR: ocrText)
        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("name:") {
                draft.name = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if lowered.hasPrefix("dose:") {
                draft.dose = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if lowered.hasPrefix("frequency:") {
                draft.frequency = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            } else if lowered.hasPrefix("notes:") {
                let notes = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if notes.lowercased() != "none" {
                    draft.notes = notes
                }
            }
        }
        draft.ocrRawText = ocrText
        return draft
    }
}

/// Prompts for model-written wellness narrative and general medication notes (with disclaimer).
public enum HealthInsightBuilder {
    public static let userFacingDisclaimer =
        "Not medical advice. Applebot is not a medical device. "
        + "General information only — verify with a clinician or pharmacist before changing anything."

    public static func narrativeRequest(
        score: WellnessScore,
        activityLine: String,
        medications: [MedicationInfo]
    ) -> LLMRequest {
        var prompt = "\(score.summaryLine)\nComponents:\n"
        for component in score.components {
            prompt += "- \(component.name): \(component.points)/\(component.maxPoints) — \(component.detail)\n"
        }
        if !activityLine.isEmpty {
            prompt += "Activity: \(activityLine)\n"
        }
        let meds = medications.filter(\.userConfirmed)
        if meds.isEmpty {
            prompt += "Medications: none listed in Applebot.\n"
        } else {
            prompt += "Medications (user-confirmed):\n"
            for med in meds.prefix(8) {
                prompt += "- \(med.displayLine)\n"
            }
        }

        return LLMRequest(
            instructions: "You write a short wellness awareness note for a private on-device health tab. "
                + "Use only the numbers and medication names provided. "
                + "Write 2 short paragraphs: (1) explain the wellness score in plain language; "
                + "(2) for each listed medication, one sentence of general information people often "
                + "associate with that medicine class (typical uses / commonly discussed side effects). "
                + "If no medications, skip paragraph 2. "
                + "Never tell the user to start, stop, or change a dose. "
                + "Never diagnose. End with exactly this line:\n"
                + "DISCLAIMER: \(userFacingDisclaimer)",
            prompt: TokenEstimator.truncate(prompt, toTokens: 600)
        )
    }
}
