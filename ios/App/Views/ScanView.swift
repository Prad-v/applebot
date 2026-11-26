import SwiftUI
import LLMKit

#if canImport(RoomPlan)
import RoomPlan
#endif

/// 3D room scan tab (RoomPlan / LiDAR) — Polycam-like capture, not Polycam itself.
struct ScanView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showCapture = false
    @State private var shareItem: ShareItem?
    @State private var renaming: RoomScanRecord?
    @State private var renameDraft = ""
    @State private var pendingName = ""

    private var scan: RoomScanController { environment.roomScan }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ApplebotTheme.spaceL) {
                    intro
                    if !scan.acceptedDisclaimer {
                        disclaimerCard
                    } else {
                        warningsCard
                        actionsCard
                        if let summary = scan.lastSummary {
                            summaryCard(summary)
                        }
                        libraryCard
                        if let status = scan.statusMessage {
                            Text(status)
                                .font(ApplebotTheme.footnote())
                                .foregroundStyle(ApplebotTheme.secondaryInk)
                        }
                        if let error = scan.errorMessage {
                            Text(error)
                                .font(ApplebotTheme.footnote())
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(ApplebotTheme.spaceL)
            }
            .applebotCanvas()
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.large)
            .task {
                scan.refreshCapabilities()
                scan.reload()
            }
            .fullScreenCover(isPresented: $showCapture) {
                #if canImport(RoomPlan)
                NavigationStack {
                    RoomCaptureSessionView(
                        onComplete: { room in
                            showCapture = false
                            Task { await scan.save(captured: room, name: pendingName) }
                        },
                        onCancel: { showCapture = false }
                    )
                }
                #else
                Text("RoomPlan is not available in this build.")
                    .padding()
                #endif
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .sheet(item: $renaming) { record in
                renameSheet(record)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3D room scan")
                .font(ApplebotTheme.title())
            Text(
                "Walk a room with LiDAR to build a 3D model (USDZ), share it, and hear a short spoken summary. "
                    + "This uses Apple RoomPlan — similar in spirit to Polycam Space mode, not the Polycam app."
            )
            .font(ApplebotTheme.footnote())
            .foregroundStyle(ApplebotTheme.secondaryInk)
            .accessibilityIdentifier("scan-intro")
        }
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceM) {
            Label("Before you scan", systemImage: "cube.transparent")
                .font(ApplebotTheme.title())
            Text(RoomScanNarrator.safetyDisclaimer)
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
            Text("Scanning needs a clear view of walls and furniture. Move slowly. Camera stays on this iPhone.")
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
            ApplebotPrimaryButton(title: "I understand — continue", systemImage: "checkmark.circle") {
                scan.acceptDisclaimer()
            }
            .accessibilityIdentifier("scan-accept")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var warningsCard: some View {
        let warnings = scan.sensorWarnings
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Sensor notes", systemImage: "exclamationmark.triangle")
                    .font(ApplebotTheme.title())
                ForEach(warnings, id: \.self) { line in
                    Text(line)
                        .font(ApplebotTheme.footnote())
                        .foregroundStyle(ApplebotTheme.secondaryInk)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("scan-sensor-warnings")
        }
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            Text("Capture")
                .font(ApplebotTheme.title())
            if scan.canScan {
                TextField("Name (optional)", text: $pendingName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("scan-name")
                ApplebotPrimaryButton(
                    title: scan.isSaving ? "Saving…" : "Scan room",
                    systemImage: "lidar.ranged"
                ) {
                    showCapture = true
                }
                .disabled(scan.isSaving)
                .accessibilityIdentifier("scan-start")
            } else {
                Text(
                    scan.capabilities.features.first(where: { $0.id == "roomplan" })?.unavailableReason
                        ?? "Room scanning is not available on this device."
                )
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
                ApplebotSecondaryButton(title: "Scan room", systemImage: "lidar.ranged") {}
                    .disabled(true)
            }
        }
    }

    private func summaryCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            HStack {
                Text("Spoken summary")
                    .font(ApplebotTheme.title())
                Spacer()
                Text(scan.usedModel ? "On-device model" : "Basic summary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(summary)
                .font(ApplebotTheme.body())
                .foregroundStyle(ApplebotTheme.ink)
                .textSelection(.enabled)
                .accessibilityIdentifier("scan-summary")
            Button("Speak again") { scan.speakSummaryAgain() }
                .buttonStyle(.bordered)
        }
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            Text("Saved scans")
                .font(ApplebotTheme.title())
            if scan.records.isEmpty {
                Text("No scans yet. Capture a room on a LiDAR iPhone to save a USDZ here.")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
            } else {
                ForEach(scan.records) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.name).font(.headline)
                        Text(metaLine(record))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Share") {
                                if let url = scan.usdzURL(for: record) {
                                    shareItem = ShareItem(url: url)
                                }
                            }
                            .buttonStyle(.bordered)
                            Button("Summarize") {
                                Task { await scan.summarize(facts: record.facts, autoSpeak: true) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(scan.isSummarizing)
                            Button("Rename") {
                                renameDraft = record.name
                                renaming = record
                            }
                            .buttonStyle(.bordered)
                            Button("Delete", role: .destructive) {
                                scan.delete(record.id)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("scan-record-\(record.id.uuidString)")
                }
            }
        }
        .accessibilityIdentifier("scan-library")
    }

    private func metaLine(_ record: RoomScanRecord) -> String {
        let mb = Double(record.byteSize) / 1_048_576
        let size = String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb)
        let f = record.facts
        return "\(f.wallCount) walls · \(f.doorCount) doors · \(f.windowCount) windows · \(size)"
    }

    private func renameSheet(_ record: RoomScanRecord) -> some View {
        NavigationStack {
            Form {
                TextField("Name", text: $renameDraft)
            }
            .navigationTitle("Rename scan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { renaming = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        scan.rename(record.id, to: renameDraft)
                        renaming = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
