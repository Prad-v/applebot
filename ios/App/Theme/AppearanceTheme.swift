import SwiftUI

/// User-selectable appearance. Each option keeps text readable on its canvas.
enum AppearanceTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case daylight
    case midnight
    case ocean
    case forest
    case highContrast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .daylight: return "Daylight"
        case .midnight: return "Midnight"
        case .ocean: return "Ocean"
        case .forest: return "Forest"
        case .highContrast: return "High contrast"
        }
    }

    var summary: String {
        switch self {
        case .system: return "Follows iOS Light or Dark. Teal accent."
        case .daylight: return "Always light. Charcoal text on white."
        case .midnight: return "Always dark. Soft white text on charcoal."
        case .ocean: return "Always light. Deep blue accent."
        case .forest: return "Always light. Green accent."
        case .highContrast: return "Always light. Strong black text and bold accent."
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .daylight: return "sun.max"
        case .midnight: return "moon.stars"
        case .ocean: return "water.waves"
        case .forest: return "leaf"
        case .highContrast: return "circle.inset.filled"
        }
    }

    /// `nil` means follow the system appearance.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .daylight, .ocean, .forest, .highContrast: return .light
        case .midnight: return .dark
        }
    }

    var tokens: ThemeTokens {
        switch self {
        case .system:
            return ThemeTokens(
                accent: Self.adaptive(
                    light: UIColor(red: 0.05, green: 0.48, blue: 0.50, alpha: 1),
                    dark: UIColor(red: 0.35, green: 0.78, blue: 0.80, alpha: 1)
                ),
                accentSoft: Self.adaptive(
                    light: UIColor(red: 0.18, green: 0.55, blue: 0.56, alpha: 1),
                    dark: UIColor(red: 0.45, green: 0.82, blue: 0.84, alpha: 1)
                ),
                ink: Color.primary,
                secondaryInk: Color.secondary,
                tertiaryInk: Color.secondary.opacity(0.75),
                canvas: Color(UIColor.systemBackground),
                userBubble: Self.adaptive(
                    light: UIColor(red: 0.05, green: 0.48, blue: 0.50, alpha: 1),
                    dark: UIColor(red: 0.20, green: 0.58, blue: 0.60, alpha: 1)
                ),
                assistantFill: Color(UIColor.secondarySystemBackground),
                hairline: Color.primary.opacity(0.12),
                onAccent: .white
            )
        case .daylight:
            return ThemeTokens(
                accent: Color(red: 0.05, green: 0.48, blue: 0.50),
                accentSoft: Color(red: 0.18, green: 0.55, blue: 0.56),
                ink: Color(red: 0.11, green: 0.13, blue: 0.15),
                secondaryInk: Color(red: 0.35, green: 0.38, blue: 0.40),
                tertiaryInk: Color(red: 0.50, green: 0.52, blue: 0.54),
                canvas: Color(red: 0.99, green: 0.99, blue: 0.99),
                userBubble: Color(red: 0.05, green: 0.48, blue: 0.50),
                assistantFill: Color(red: 0.94, green: 0.95, blue: 0.96),
                hairline: Color.black.opacity(0.10),
                onAccent: .white
            )
        case .midnight:
            return ThemeTokens(
                accent: Color(red: 0.40, green: 0.82, blue: 0.84),
                accentSoft: Color(red: 0.55, green: 0.88, blue: 0.90),
                ink: Color(red: 0.96, green: 0.97, blue: 0.98),
                secondaryInk: Color(red: 0.75, green: 0.78, blue: 0.80),
                tertiaryInk: Color(red: 0.58, green: 0.62, blue: 0.64),
                canvas: Color(red: 0.07, green: 0.09, blue: 0.10),
                userBubble: Color(red: 0.18, green: 0.52, blue: 0.54),
                assistantFill: Color(red: 0.14, green: 0.16, blue: 0.18),
                hairline: Color.white.opacity(0.14),
                onAccent: Color(red: 0.05, green: 0.10, blue: 0.11)
            )
        case .ocean:
            return ThemeTokens(
                accent: Color(red: 0.08, green: 0.36, blue: 0.62),
                accentSoft: Color(red: 0.20, green: 0.48, blue: 0.72),
                ink: Color(red: 0.08, green: 0.12, blue: 0.20),
                secondaryInk: Color(red: 0.30, green: 0.36, blue: 0.44),
                tertiaryInk: Color(red: 0.48, green: 0.52, blue: 0.58),
                canvas: Color(red: 0.97, green: 0.98, blue: 1.00),
                userBubble: Color(red: 0.08, green: 0.36, blue: 0.62),
                assistantFill: Color(red: 0.90, green: 0.93, blue: 0.97),
                hairline: Color.black.opacity(0.10),
                onAccent: .white
            )
        case .forest:
            return ThemeTokens(
                accent: Color(red: 0.16, green: 0.45, blue: 0.30),
                accentSoft: Color(red: 0.28, green: 0.55, blue: 0.40),
                ink: Color(red: 0.10, green: 0.14, blue: 0.12),
                secondaryInk: Color(red: 0.32, green: 0.38, blue: 0.34),
                tertiaryInk: Color(red: 0.48, green: 0.52, blue: 0.48),
                canvas: Color(red: 0.98, green: 0.99, blue: 0.97),
                userBubble: Color(red: 0.16, green: 0.45, blue: 0.30),
                assistantFill: Color(red: 0.92, green: 0.95, blue: 0.92),
                hairline: Color.black.opacity(0.10),
                onAccent: .white
            )
        case .highContrast:
            return ThemeTokens(
                accent: Color(red: 0.00, green: 0.40, blue: 0.42),
                accentSoft: Color(red: 0.00, green: 0.48, blue: 0.50),
                ink: Color.black,
                secondaryInk: Color(red: 0.15, green: 0.15, blue: 0.15),
                tertiaryInk: Color(red: 0.30, green: 0.30, blue: 0.30),
                canvas: Color.white,
                userBubble: Color(red: 0.00, green: 0.40, blue: 0.42),
                assistantFill: Color(red: 0.92, green: 0.92, blue: 0.92),
                hairline: Color.black.opacity(0.22),
                onAccent: .white
            )
        }
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

struct ThemeTokens {
    var accent: Color
    var accentSoft: Color
    /// Primary readable text on the canvas.
    var ink: Color
    var secondaryInk: Color
    var tertiaryInk: Color
    var canvas: Color
    var userBubble: Color
    var assistantFill: Color
    var hairline: Color
    var onAccent: Color
}
