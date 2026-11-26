import Foundation
import Observation
import SwiftUI

/// Persists and publishes the user's appearance choice.
@MainActor
@Observable
final class ThemeController {
    /// Nested so the key stays nonisolated (Swift 6); safe to use from `AppEnvironment.Keys`.
    enum Keys {
        static let appearanceTheme = "appearanceTheme"
    }

    var selection: AppearanceTheme {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: Keys.appearanceTheme)
        }
    }

    var tokens: ThemeTokens { selection.tokens }
    var preferredColorScheme: ColorScheme? { selection.preferredColorScheme }
    var accent: Color { tokens.accent }
    var ink: Color { tokens.ink }

    init(defaults: UserDefaults = .standard) {
        let raw = defaults.string(forKey: Keys.appearanceTheme) ?? ""
        selection = AppearanceTheme(rawValue: raw) ?? .system
    }
}
