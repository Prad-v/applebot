import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            TabView {
                Tab("Chats", systemImage: "bubble.left.and.bubble.right") {
                    ChatsView()
                }
                Tab("Documents", systemImage: "doc.text.magnifyingglass") {
                    DocumentsView()
                }
                Tab("Settings", systemImage: "gearshape") {
                    SettingsView()
                }
            }
            .blur(radius: environment.isLocked ? 24 : 0)
            .allowsHitTesting(!environment.isLocked)

            if environment.isLocked {
                LockView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: environment.isLocked)
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
    }
}

struct LockView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Applebot is locked")
                .font(.title2.bold())
            Text("Your chats and documents stay private.")
                .foregroundStyle(.secondary)
            Button("Unlock") {
                Task { await environment.unlock() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .task { await environment.unlock() }
    }
}

/// Banner shown when the active model cannot answer yet.
struct AvailabilityBanner: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !environment.availability.isAvailable {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(environment.availability.message)
                        .font(.subheadline)
                    if environment.externalModelEnabled {
                        Text("Fix the external model in Settings, or turn it off to use Apple Intelligence on this iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if environment.availability == .appleIntelligenceDisabled,
                              let url = URL(string: "app-settings:") {
                        Button("Open Settings") { openURL(url) }
                            .font(.subheadline.bold())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("availability-banner")
        } else if environment.isUsingExternalModel {
            HStack(spacing: 10) {
                Image(systemName: "cloud")
                    .foregroundStyle(.secondary)
                Text("Using \(environment.modelSummary). Messages leave this iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("external-model-banner")
        }
    }
}
