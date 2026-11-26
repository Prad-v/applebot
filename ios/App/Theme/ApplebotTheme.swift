import SwiftUI

/// Lightweight modern language: flat canvas, hairlines, typography over chrome.
/// Colors come from the selected `AppearanceTheme` via `ThemeController`.
enum ApplebotTheme {
    // MARK: Palette (resolved from the active theme)

    @MainActor static var accent: Color { ThemeControllerBridge.tokens.accent }
    @MainActor static var accentSoft: Color { ThemeControllerBridge.tokens.accentSoft }
    @MainActor static var ink: Color { ThemeControllerBridge.tokens.ink }
    @MainActor static var secondaryInk: Color { ThemeControllerBridge.tokens.secondaryInk }
    @MainActor static var tertiaryInk: Color { ThemeControllerBridge.tokens.tertiaryInk }
    @MainActor static var canvas: Color { ThemeControllerBridge.tokens.canvas }
    @MainActor static var userBubble: Color { ThemeControllerBridge.tokens.userBubble }
    @MainActor static var assistantFill: Color { ThemeControllerBridge.tokens.assistantFill }
    @MainActor static var hairline: Color { ThemeControllerBridge.tokens.hairline }
    @MainActor static var onAccent: Color { ThemeControllerBridge.tokens.onAccent }
    @MainActor static var warning: Color { Color(red: 0.78, green: 0.45, blue: 0.12) }
    @MainActor static var danger: Color { Color(red: 0.78, green: 0.25, blue: 0.22) }

    // MARK: Spacing

    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 16
    static let spaceL: CGFloat = 28
    static let spaceXL: CGFloat = 40

    static let radiusS: CGFloat = 10
    static let radiusM: CGFloat = 14
    static let radiusL: CGFloat = 20
    static let radiusPill: CGFloat = 22

    // MARK: Typography

    static func brand(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .medium, design: .serif)
    }

    static func display(_ size: CGFloat = 26) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }

    static func title() -> Font {
        .system(.title3, design: .default).weight(.medium)
    }

    static func body() -> Font {
        .system(.body, design: .default)
    }

    static func caption() -> Font {
        .system(.caption, design: .default)
    }

    static func footnote() -> Font {
        .system(.footnote, design: .default)
    }
}

/// Lets static theme accessors read the live controller without every call site wiring Environment.
@MainActor
enum ThemeControllerBridge {
    static weak var controller: ThemeController?
    static var tokens: ThemeTokens {
        controller?.tokens ?? AppearanceTheme.system.tokens
    }
}

// MARK: - Shared modifiers

extension View {
    /// Flat canvas from the active theme.
    func applebotCanvas() -> some View {
        background(ApplebotTheme.canvas.ignoresSafeArea())
    }

    func applebotQuietSurface(padding: CGFloat = ApplebotTheme.spaceM) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: ApplebotTheme.radiusM, style: .continuous)
                    .fill(ApplebotTheme.assistantFill.opacity(0.9))
            )
    }

    func applebotHairlineDivider() -> some View {
        self.overlay(alignment: .bottom) {
            Rectangle()
                .fill(ApplebotTheme.hairline)
                .frame(height: 0.33)
        }
    }

    func applebotSectionTitle() -> some View {
        self
            .font(.system(.caption, design: .default).weight(.semibold))
            .foregroundStyle(ApplebotTheme.tertiaryInk)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}
