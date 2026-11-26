import SwiftUI

/// Lets the user pick a comfortable appearance with readable text contrast.
struct ThemeSettingsView: View {
    @Environment(ThemeController.self) private var theme

    var body: some View {
        @Bindable var theme = theme

        List {
            Section {
                ForEach(AppearanceTheme.allCases) { option in
                    Button {
                        theme.selection = option
                    } label: {
                        ThemeOptionRow(
                            option: option,
                            isSelected: theme.selection == option
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("theme-\(option.rawValue)")
                }
            } header: {
                Text("Appearance").applebotSectionTitle()
            } footer: {
                Text("Themes change accent colour, text contrast, and whether the app follows Light or Dark. System follows your iPhone setting.")
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
            }

            Section {
                ThemePreviewCard(tokens: theme.tokens)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Preview").applebotSectionTitle()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .applebotCanvas()
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThemeOptionRow: View {
    let option: AppearanceTheme
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: option.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(option.tokens.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(option.displayName)
                    .font(.system(.body, design: .default).weight(.medium))
                    .foregroundStyle(ApplebotTheme.ink)
                Text(option.summary)
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ApplebotTheme.accent)
                    .accessibilityLabel("Selected")
            }

            HStack(spacing: 4) {
                Circle().fill(option.tokens.accent).frame(width: 12, height: 12)
                Circle().fill(option.tokens.ink).frame(width: 12, height: 12)
                Circle().fill(option.tokens.canvas)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(ApplebotTheme.hairline, lineWidth: 1))
            }
            .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct ThemePreviewCard: View {
    let tokens: ThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Applebot")
                .font(ApplebotTheme.brand(18))
                .foregroundStyle(tokens.ink)
            Text("Preview message from you")
                .font(ApplebotTheme.footnote())
                .foregroundStyle(tokens.onAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(tokens.userBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("A calm reply on this theme’s canvas.")
                .font(ApplebotTheme.footnote())
                .foregroundStyle(tokens.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(tokens.assistantFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Secondary text stays readable.")
                .font(ApplebotTheme.caption())
                .foregroundStyle(tokens.secondaryInk)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tokens.hairline, lineWidth: 1)
        )
    }
}
