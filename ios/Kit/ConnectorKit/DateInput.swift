import Foundation

/// Parses the date strings a small language model produces. The tool descriptions ask for
/// `YYYY-MM-DD` or `YYYY-MM-DD HH:mm`, but models also send ISO-8601 or words like "tomorrow".
public enum DateInput {
    public struct Parsed: Equatable, Sendable {
        public var date: Date
        /// False when only a day was given (the date is then the start of that day).
        public var hasTime: Bool
    }

    public static func parse(_ text: String, now: Date, calendar: Calendar) -> Parsed? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let lowered = cleaned.lowercased()

        switch lowered {
        case "now":
            return Parsed(date: now, hasTime: true)
        case "today":
            return Parsed(date: calendar.startOfDay(for: now), hasTime: false)
        case "tomorrow":
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                .map { Parsed(date: $0, hasTime: false) }
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
                .map { Parsed(date: $0, hasTime: false) }
        default:
            break
        }

        // Explicit offsets ("2026-11-21T15:00:00Z", "...+01:00") win over the local time zone.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: cleaned) { return Parsed(date: date, hasTime: true) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: cleaned) { return Parsed(date: date, hasTime: true) }

        let candidates: [(format: String, hasTime: Bool)] = [
            ("yyyy-MM-dd'T'HH:mm:ss", true),
            ("yyyy-MM-dd'T'HH:mm", true),
            ("yyyy-MM-dd HH:mm:ss", true),
            ("yyyy-MM-dd HH:mm", true),
            ("yyyy-MM-dd", false),
        ]
        for candidate in candidates {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = candidate.format
            formatter.isLenient = false
            if let date = formatter.date(from: cleaned) {
                return Parsed(date: date, hasTime: candidate.hasTime)
            }
        }
        return nil
    }

    /// Compact, unambiguous rendering for tool output, for example `Sat 2026-11-21 15:00`.
    static func format(_ date: Date, calendar: Calendar, includeTime: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = includeTime ? "EEE yyyy-MM-dd HH:mm" : "EEE yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func formatTime(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
