import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeController.self) private var theme
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var environment = environment
        ZStack {
            TabView(selection: $environment.selectedTab) {
                Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: AppTab.chat) {
                    ChatsView()
                }
                Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                    DocumentsView()
                }
                Tab("Health", systemImage: "heart.text.square", value: AppTab.health) {
                    HealthView()
                }
                Tab("Stocks", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.stocks) {
                    StocksView()
                }
                Tab("Trail", systemImage: "map", value: AppTab.trail) {
                    WildernessView()
                }
                Tab("Surroundings", systemImage: "eye", value: AppTab.surroundings) {
                    SurroundingsView()
                }
                Tab("Scan", systemImage: "cube", value: AppTab.scan) {
                    ScanView()
                }
                Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                    SettingsView()
                }
            }
            .tint(theme.accent)
            .blur(radius: environment.isLocked ? 28 : 0)
            .allowsHitTesting(!environment.isLocked)

            if environment.isLocked {
                LockView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: environment.isLocked)
        .onAppear { environment.attachModelContext(modelContext) }
        // Actions the assistant proposes (save a draft, add an event) always wait for the user here.
        // Dismissing the sheet counts as "Don't allow".
        .sheet(item: Binding(
            get: { environment.approvals.pending },
            set: { if $0 == nil { environment.approvals.resolve(false) } }
        )) { request in
            ApprovalSheet(request: request) { approved in
                environment.approvals.resolve(approved, requestID: request.id)
            }
        }
        .sheet(isPresented: Binding(
            get: { environment.dailyBrief.pendingBrief != nil && !environment.isLocked },
            set: { if !$0 { environment.dailyBrief.dismiss() } }
        )) {
            if let brief = environment.dailyBrief.pendingBrief {
                DailyBriefSheet(brief: brief) {
                    environment.dailyBrief.dismiss()
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { environment.checkIns.pending != nil && environment.dailyBrief.pendingBrief == nil && !environment.isLocked },
            set: { if !$0 { environment.checkIns.dismiss() } }
        )) {
            if let suggestion = environment.checkIns.pending {
                CheckInSheet(
                    suggestion: suggestion,
                    onAccept: { prompt in
                        environment.checkIns.dismiss()
                        environment.pendingChatPrompt = prompt
                    },
                    onDismiss: { environment.checkIns.dismiss() }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: {
                environment.automations.dueRecipe != nil
                    && environment.dailyBrief.pendingBrief == nil
                    && environment.checkIns.pending == nil
                    && !environment.isLocked
            },
            set: { if !$0 { environment.automations.dismissDue() } }
        )) {
            if let recipe = environment.automations.dueRecipe {
                AutomationDueSheet(
                    recipe: recipe,
                    onRun: { recipe in
                        environment.automations.markDueRan()
                        environment.pendingChatPrompt = recipe.prompt
                    },
                    onDismiss: { environment.automations.dismissDue() }
                )
            }
        }
    }
}

struct LockView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: ApplebotTheme.spaceM) {
            Spacer()

            Image(systemName: "lock")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ApplebotTheme.accent)
                .frame(width: 56, height: 56)
                .background(Circle().strokeBorder(ApplebotTheme.accent.opacity(0.25), lineWidth: 1))

            Text("Applebot")
                .font(ApplebotTheme.brand(24))
                .foregroundStyle(ApplebotTheme.ink)

            Text("Private and locked")
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)

            ApplebotPrimaryButton(title: "Unlock", systemImage: "faceid") {
                Task { await environment.unlock() }
            }
            .frame(maxWidth: 200)
            .padding(.top, 8)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .applebotCanvas()
        .task { await environment.unlock() }
    }
}

/// Banner shown when the active model cannot answer yet.
struct AvailabilityBanner: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !environment.availability.isAvailable {
            ApplebotBanner(
                kind: .warning,
                icon: "exclamationmark.triangle.fill",
                title: environment.availability.message,
                detail: environment.externalModelEnabled
                    ? "Fix the external model in You, or turn it off to use Apple Intelligence on this iPhone."
                    : nil,
                actionTitle: (!environment.externalModelEnabled && environment.availability == .appleIntelligenceDisabled)
                    ? "Open Settings" : nil,
                action: {
                    if let url = URL(string: "app-settings:") { openURL(url) }
                }
            )
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("availability-banner")
        } else if environment.isUsingExternalModel {
            ApplebotBanner(
                kind: .info,
                icon: "cloud",
                title: "Using \(environment.modelSummary). Messages leave this iPhone."
            )
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("external-model-banner")
        }
    }
}
