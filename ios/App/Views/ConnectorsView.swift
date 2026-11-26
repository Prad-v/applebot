import SwiftUI
import ConnectorKit
import LLMKit

/// Settings > Connectors: connect accounts and switch each one on or off for chats.
struct ConnectorsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let model = environment.connectors
        List {
            Section {
                Text("Connectors let Applebot look things up in your accounts and on the web, such as weather, stock prices and news, when you ask. It only uses a connector while it is switched on, and it asks before it changes anything.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                ConnectorRow(row: row, model: model)
            }
        }
        .navigationTitle("Connectors")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .alert("Couldn't connect", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct ConnectorRow: View {
    let row: ConnectorInfo
    let model: ConnectorsModel

    private var isBusy: Bool { model.busyID == row.id }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: row.symbolName)
                    .font(.title3)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName).font(.headline)
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if isBusy { ProgressView() }
            }
            .accessibilityElement(children: .combine)

            switch row.status {
            case .notConnected:
                Button("Connect \(row.displayName)") {
                    Task { await model.connect(row.id) }
                }
                .disabled(model.busyID != nil)
                .accessibilityIdentifier("connect-\(row.id)")

            case .connected:
                Toggle("Use in chats", isOn: Binding(
                    get: { row.isEnabled },
                    set: { value in Task { await model.setEnabled(row.id, value) } }
                ))
                .accessibilityIdentifier("toggle-\(row.id)")
                if row.hasAccount {
                    Button("Disconnect", role: .destructive) {
                        Task { await model.disconnect(row.id) }
                    }
                    .disabled(model.busyID != nil)
                    .accessibilityIdentifier("disconnect-\(row.id)")
                }

            case .unavailable:
                EmptyView()
            }
        } header: {
            EmptyView()
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.summary)
                Text(row.dataNote)
            }
        }
    }

    private var statusText: String {
        switch row.status {
        case .notConnected: return "Not connected"
        case .connected(let account):
            // Keyless lookups (weather, stocks, web search) have nothing to sign in to;
            // "On" / "Off" matches the Use in chats toggle better than "Connected · paused".
            if !row.hasAccount {
                return row.isEnabled ? "On" : "Off"
            }
            let name = account.map { "Connected as \($0)" } ?? "Connected"
            return row.isEnabled ? name : name + " · paused"
        case .unavailable(let why): return why
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .connected: return row.isEnabled ? .green : .secondary
        case .notConnected: return .secondary
        case .unavailable: return .orange
        }
    }
}

/// Shown whenever the assistant wants to change something. Displays the exact content so the user
/// approves what will really happen, not a summary of it.
struct ApprovalSheet: View {
    let request: ApprovalRequest
    var onDecision: (Bool) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ApplebotTheme.spaceM) {
                Text("Nothing happens unless you approve.")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(request.detail)
                        .font(ApplebotTheme.body())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("approval-detail")

                VStack(spacing: 8) {
                    Button {
                        onDecision(true)
                    } label: {
                        Text(request.confirmLabel)
                            .font(.system(.subheadline, design: .default).weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(ApplebotTheme.onAccent)
                            .background(ApplebotTheme.accent, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("approval-approve")

                    Button {
                        onDecision(false)
                    } label: {
                        Text("Don't allow")
                            .font(.system(.subheadline, design: .default).weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(ApplebotTheme.accent)
                            .background(
                                Capsule(style: .continuous)
                                    .strokeBorder(ApplebotTheme.accent.opacity(0.28), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("approval-decline")
                }
            }
            .padding(ApplebotTheme.spaceM)
            .applebotCanvas()
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Explains why connectors are idle in a chat that is answering from documents, and offers the fix.
///
/// Document answers are told to use only the retrieved passages, which conflicts with calling
/// tools, so the pipeline offers connector tools only when documents are off for the chat.
struct ConnectorNotice: View {
    @Bindable var conversation: Conversation
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let active = environment.connectors.activeNames
        let names = ListFormatter.localizedString(byJoining: active)
        if !active.isEmpty, conversation.useDocuments, !environment.documents.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(ApplebotTheme.accentSoft)
                    .font(.body.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(names) won't be used while this chat searches your documents.")
                        .font(ApplebotTheme.footnote())
                    Button("Use \(names) instead") {
                        conversation.useDocuments = false
                    }
                    .font(ApplebotTheme.footnote().weight(.semibold))
                    .accessibilityIdentifier("use-connectors-instead")
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: ApplebotTheme.radiusS, style: .continuous)
                    .fill(ApplebotTheme.accent.opacity(0.08))
            )
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("connector-notice")
        }
    }
}
