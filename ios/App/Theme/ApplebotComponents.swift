import SwiftUI

/// Compact filled CTA.
struct ApplebotPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                }
                Text(title)
                    .font(.system(.subheadline, design: .default).weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(ApplebotTheme.onAccent)
            .background(ApplebotTheme.accent, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Text-forward secondary action.
struct ApplebotSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.medium))
                }
                Text(title)
                    .font(.system(.subheadline, design: .default).weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(ApplebotTheme.accent)
            .background(
                Capsule(style: .continuous)
                    .strokeBorder(ApplebotTheme.accent.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Suggestion as a light text row, not a heavy chip.
struct ApplebotSuggestionChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(ApplebotTheme.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ApplebotTheme.tertiaryInk)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(ApplebotTheme.hairline)
                    .frame(height: 0.33)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Minimal filter pill.
struct ApplebotPill: View {
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        let label = HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(title)
                .font(ApplebotTheme.caption().weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? ApplebotTheme.onAccent : ApplebotTheme.secondaryInk)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected ? ApplebotTheme.accent : ApplebotTheme.ink.opacity(0.06))
        )

        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }
}

/// Airy empty / hero state — icon + type, no pulse animation.
struct ApplebotHeroEmpty: View {
    let symbol: String
    let title: String
    let message: String
    var primaryTitle: String? = nil
    var primarySystemImage: String? = nil
    var primaryAction: (() -> Void)? = nil
    var showBrand: Bool = true

    var body: some View {
        VStack(spacing: ApplebotTheme.spaceM) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ApplebotTheme.accent)
                .frame(width: 52, height: 52)
                .background(
                    Circle().strokeBorder(ApplebotTheme.accent.opacity(0.22), lineWidth: 1)
                )

            if showBrand {
                Text("Applebot")
                    .font(ApplebotTheme.brand(20))
                    .foregroundStyle(ApplebotTheme.ink)
            }

            Text(title)
                .font(ApplebotTheme.display(24))
                .multilineTextAlignment(.center)
                .foregroundStyle(ApplebotTheme.ink)

            Text(message)
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .lineSpacing(2)

            if let primaryTitle, let primaryAction {
                ApplebotPrimaryButton(title: primaryTitle, systemImage: primarySystemImage, action: primaryAction)
                    .frame(maxWidth: 240)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, ApplebotTheme.spaceL)
        .padding(.vertical, ApplebotTheme.spaceXL)
        .frame(maxWidth: .infinity)
    }
}

/// Flat banner — tint wash only.
struct ApplebotBanner: View {
    enum Kind { case warning, info }

    let kind: Kind
    let icon: String
    let title: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(kind == .warning ? ApplebotTheme.warning : ApplebotTheme.accentSoft)
                .font(.footnote.weight(.semibold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ApplebotTheme.footnote())
                if let detail {
                    Text(detail)
                        .font(ApplebotTheme.caption())
                        .foregroundStyle(ApplebotTheme.secondaryInk)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(ApplebotTheme.footnote().weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: ApplebotTheme.radiusS, style: .continuous)
                .fill(kind == .warning
                      ? ApplebotTheme.warning.opacity(0.08)
                      : ApplebotTheme.accent.opacity(0.06))
        )
    }
}

enum ApplebotGreeting {
    static func line(name: String?) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part: String
        switch hour {
        case 5..<12: part = "Good morning"
        case 12..<17: part = "Good afternoon"
        case 17..<22: part = "Good evening"
        default: part = "Hello"
        }
        if let name, !name.isEmpty {
            return "\(part), \(name)"
        }
        return part
    }
}
