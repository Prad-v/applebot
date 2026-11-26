import SwiftUI
import ConnectorKit
import LLMKit

/// Accessibility tab: describe what's in front of the camera using on-device Vision + model + speech.
struct SurroundingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var captureTrigger = 0
    @State private var sessionRunning = false
    @State private var cameraError: String?

    private var surroundings: SurroundingsController { environment.surroundings }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ApplebotTheme.spaceL) {
                    intro
                    if !surroundings.acceptedSafetyDisclaimer {
                        safetyCard
                    } else {
                        warningsCard
                        permissionCard
                        if surroundings.cameraAuthorized {
                            cameraCard
                            controlsCard
                        }
                        resultCard
                    }
                }
                .padding(ApplebotTheme.spaceL)
            }
            .applebotCanvas()
            .navigationTitle("Surroundings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if surroundings.narration != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            surroundings.speakAgain()
                        } label: {
                            Label("Speak again", systemImage: "speaker.wave.2.fill")
                        }
                        .accessibilityIdentifier("surroundings-speak-again")
                    }
                }
            }
            .task {
                surroundings.refreshCapabilities()
                surroundings.refreshCameraPermission()
            }
            .onDisappear {
                surroundings.stopLiveMode(announceStop: false)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Understand what’s around you")
                .font(ApplebotTheme.title())
            Text(
                "Point the rear camera, then describe once or turn on Live mode for continuous spoken updates. "
                    + "Analysis stays on this iPhone. This is assistive only — not for navigation."
            )
            .font(ApplebotTheme.footnote())
            .foregroundStyle(ApplebotTheme.secondaryInk)
            .accessibilityIdentifier("surroundings-intro")
        }
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceM) {
            Label("Important", systemImage: "hand.raised.fill")
                .font(ApplebotTheme.title())
            Text(SurroundingsNarrator.safetyDisclaimer)
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
            ApplebotPrimaryButton(title: "I understand — continue", systemImage: "checkmark.circle") {
                surroundings.acceptSafetyDisclaimer()
                Task { await surroundings.requestCameraAccess() }
            }
            .accessibilityIdentifier("surroundings-accept-safety")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var warningsCard: some View {
        let warnings = surroundings.sensorWarnings
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
            .accessibilityIdentifier("surroundings-sensor-warnings")
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
            Text("Camera")
                .font(ApplebotTheme.title())
            if surroundings.cameraAuthorized {
                Text(sessionRunning ? "Camera is on." : "Starting camera…")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
            } else {
                Text("Allow Camera so Applebot can look at what’s in front of you.")
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(ApplebotTheme.secondaryInk)
                ApplebotSecondaryButton(title: "Allow Camera", systemImage: "camera") {
                    Task { await surroundings.requestCameraAccess() }
                }
                .accessibilityIdentifier("surroundings-allow-camera")
            }
            if let cameraError {
                Text(cameraError)
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(.orange)
            }
            if let error = surroundings.errorMessage {
                Text(error)
                    .font(ApplebotTheme.footnote())
                    .foregroundStyle(.orange)
            }
        }
    }

    private var cameraCard: some View {
        SurroundingsCameraPreview(
            onCapture: { image in
                Task { await surroundings.describe(image: image, autoSpeak: true) }
            },
            onLiveFrame: { image in
                surroundings.handleLiveFrame(image)
            },
            liveFramesEnabled: surroundings.isLiveMode,
            captureTrigger: $captureTrigger,
            sessionRunning: $sessionRunning,
            cameraError: $cameraError
        )
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            surroundings.isLiveMode
                ? "Live camera preview. Live mode is on and will speak when the scene changes."
                : "Live camera preview. Point the phone at the area you want described."
        )
        .accessibilityIdentifier("surroundings-camera")
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: ApplebotTheme.spaceM) {
            ApplebotPrimaryButton(
                title: surroundings.isBusy && !surroundings.isLiveMode
                    ? "Describing…"
                    : "Describe what’s around me",
                systemImage: "eye"
            ) {
                guard !surroundings.isBusy || surroundings.isLiveMode else { return }
                // One-shot still works during live; briefly ok to overlap analysis.
                captureTrigger += 1
            }
            .disabled((surroundings.isBusy && !surroundings.isLiveMode) || !surroundings.canDescribe)
            .accessibilityIdentifier("surroundings-describe")

            Toggle(isOn: Binding(
                get: { surroundings.isLiveMode },
                set: { surroundings.setLiveMode($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live mode")
                    Text(
                        surroundings.isLiveMode
                            ? "On — speaks when the scene changes (no need to tap each time)"
                            : "Off — turn on for continuous spoken updates"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .disabled(!surroundings.canDescribe)
            .accessibilityIdentifier("surroundings-live-toggle")

            Text(
                surroundings.isLiveMode
                    ? "Leave this tab or turn Live mode off to stop. Assistive only — not for navigation."
                    : "Double-tap Describe for a single description, or enable Live mode."
            )
            .font(ApplebotTheme.footnote())
            .foregroundStyle(ApplebotTheme.secondaryInk)
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        if let status = surroundings.statusMessage, surroundings.narration == nil || surroundings.isLiveMode {
            Text(status)
                .font(ApplebotTheme.footnote())
                .foregroundStyle(ApplebotTheme.secondaryInk)
                .accessibilityIdentifier("surroundings-status")
        }
        if let narration = surroundings.narration {
            VStack(alignment: .leading, spacing: ApplebotTheme.spaceS) {
                HStack {
                    Text(surroundings.isLiveMode ? "Latest live update" : "Description")
                        .font(ApplebotTheme.title())
                    Spacer()
                    if surroundings.usedModel {
                        Text("On-device model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Basic summary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(narration)
                    .font(ApplebotTheme.body())
                    .foregroundStyle(ApplebotTheme.ink)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("surroundings-narration")

                HStack {
                    Button("Speak again") { surroundings.speakAgain() }
                        .buttonStyle(.bordered)
                    Button("Clear") { surroundings.clearNarration() }
                        .buttonStyle(.bordered)
                    if surroundings.isLiveMode {
                        Button("Stop live", role: .destructive) {
                            surroundings.setLiveMode(false)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("surroundings-live-stop")
                    }
                }
            }
        }
    }
}
