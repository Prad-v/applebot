import Foundation
import Observation
import UIKit
import AVFoundation
import ConnectorKit
import LLMKit

/// Surroundings tab: one-shot describe + optional Live mode (continuous, change-gated speech).
@MainActor
@Observable
final class SurroundingsController {
    private(set) var capabilities: SurroundingsCapabilities = .airTypical
    private(set) var cameraAuthorized = false
    private(set) var isBusy = false
    private(set) var isLiveMode = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var lastFacts: SurroundingsFacts?
    private(set) var narration: String?
    private(set) var usedModel = false
    private(set) var acceptedSafetyDisclaimer: Bool
    private(set) var liveUpdateCount = 0

    @ObservationIgnored private var engine: (() -> any LLMEngine)?
    @ObservationIgnored private var speak: ((String) -> Void)?
    @ObservationIgnored private var isSpeaking: (() -> Bool)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLiveImage: UIImage?
    @ObservationIgnored private var lastLiveSpeakAt: Date?
    /// Minimum time between spoken live updates.
    @ObservationIgnored private let liveSpeakMinInterval: TimeInterval = 6

    private enum Keys {
        static let acceptedSafety = "surroundingsAcceptedSafety"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        acceptedSafetyDisclaimer = defaults.bool(forKey: Keys.acceptedSafety)
        capabilities = SurroundingsVisionAnalyzer.capabilities()
    }

    var sensorWarnings: [String] {
        capabilities.warnings
    }

    var canDescribe: Bool {
        acceptedSafetyDisclaimer && capabilities.describeSupported && cameraAuthorized
    }

    func configure(
        engine: @escaping () -> any LLMEngine,
        speak: @escaping (String) -> Void,
        isSpeaking: @escaping () -> Bool = { false }
    ) {
        self.engine = engine
        self.speak = speak
        self.isSpeaking = isSpeaking
    }

    func refreshCapabilities() {
        capabilities = SurroundingsVisionAnalyzer.capabilities()
    }

    func acceptSafetyDisclaimer() {
        acceptedSafetyDisclaimer = true
        defaults.set(true, forKey: Keys.acceptedSafety)
        announce(SurroundingsNarrator.safetyDisclaimer)
    }

    func refreshCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined, .denied, .restricted:
            cameraAuthorized = false
        @unknown default:
            cameraAuthorized = false
        }
    }

    func requestCameraAccess() async {
        errorMessage = nil
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraAuthorized = granted
            if !granted {
                errorMessage = SurroundingsError.permissionDenied.localizedDescription
            }
        case .denied, .restricted:
            cameraAuthorized = false
            errorMessage = SurroundingsError.permissionDenied.localizedDescription
        @unknown default:
            cameraAuthorized = false
        }
    }

    // MARK: One-shot

    /// Analyze a captured still and narrate (spoken + on-screen).
    func describe(image: UIImage, autoSpeak: Bool = true) async {
        guard acceptedSafetyDisclaimer else {
            errorMessage = "Accept the safety note before describing surroundings."
            return
        }
        refreshCapabilities()
        guard capabilities.describeSupported else {
            errorMessage = capabilities.features.first(where: { $0.id == "surroundings-describe" })?.warningLine
                ?? "Describe surroundings is unavailable on this device."
            announce(errorMessage ?? "")
            return
        }

        isBusy = true
        errorMessage = nil
        statusMessage = "Analyzing the scene on this iPhone…"
        announce(statusMessage ?? "")
        defer { isBusy = false }

        do {
            let facts = try await SurroundingsVisionAnalyzer.analyze(image: image)
            lastFacts = facts

            statusMessage = "Writing a short description…"
            let text: String
            if let engine, let raw = try? await engine().respond(SurroundingsNarrator.narrationRequest(facts: facts)) {
                text = SurroundingsNarrator.normalizeModelOutput(raw, facts: facts)
                usedModel = true
            } else {
                text = SurroundingsNarrator.mechanicalNarration(facts)
                usedModel = false
            }
            narration = text
            statusMessage = usedModel ? "Description ready." : "Description ready (basic summary)."
            announce(text)
            if autoSpeak {
                speak?(text)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = nil
            announce(errorMessage ?? "Description failed.")
        }
    }

    // MARK: Live mode

    func setLiveMode(_ on: Bool) {
        guard on != isLiveMode else { return }
        if on {
            guard canDescribe else {
                errorMessage = "Allow Camera and accept the safety note before starting Live mode."
                announce(errorMessage ?? "")
                return
            }
            // Thermal pause: skip starting when seriously elevated.
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical {
                errorMessage = "This iPhone is warm. Live mode is paused — try again when it cools, or use Describe once."
                announce(errorMessage ?? "")
                return
            }
            isLiveMode = true
            liveUpdateCount = 0
            errorMessage = nil
            statusMessage = "Live mode on. I’ll speak when the scene changes."
            announce(statusMessage ?? "")
            announce(SurroundingsNarrator.safetyDisclaimer)
            startLiveLoop()
        } else {
            stopLiveMode(announceStop: true)
        }
    }

    func stopLiveMode(announceStop: Bool = false) {
        isLiveMode = false
        liveTask?.cancel()
        liveTask = nil
        pendingLiveImage = nil
        if announceStop {
            statusMessage = "Live mode off."
            announce(statusMessage ?? "")
        }
    }

    /// Called from the camera preview when Live frames are enabled.
    func handleLiveFrame(_ image: UIImage) {
        guard isLiveMode else { return }
        pendingLiveImage = image
    }

    private func startLiveLoop() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.isLiveMode {
                    await self.processPendingLiveFrameIfNeeded()
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func processPendingLiveFrameIfNeeded() async {
        guard isLiveMode, !isBusy else { return }
        guard let image = pendingLiveImage else { return }
        pendingLiveImage = nil

        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            stopLiveMode(announceStop: false)
            errorMessage = "Live mode paused because this iPhone is warm. Use Describe for a single update."
            announce(errorMessage ?? "")
            return
        }

        // Don’t stack speech.
        if isSpeaking?() == true { return }
        if let last = lastLiveSpeakAt, Date().timeIntervalSince(last) < liveSpeakMinInterval {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let facts = try await SurroundingsVisionAnalyzer.analyze(image: image)
            let previous = lastFacts
            guard SurroundingsNarrator.hasMeaningfulChange(from: previous, to: facts) else {
                statusMessage = "Live mode on — watching…"
                return
            }

            statusMessage = "Live update…"
            let text: String
            if let engine,
               let raw = try? await engine().respond(
                SurroundingsNarrator.liveNarrationRequest(facts: facts, previous: previous)
               ) {
                text = SurroundingsNarrator.normalizeLiveOutput(raw, facts: facts, previous: previous)
                usedModel = true
            } else {
                text = SurroundingsNarrator.mechanicalLiveUpdate(previous: previous, current: facts)
                usedModel = false
            }

            lastFacts = facts
            narration = text
            liveUpdateCount += 1
            lastLiveSpeakAt = Date()
            statusMessage = "Live mode on — \(liveUpdateCount) update\(liveUpdateCount == 1 ? "" : "s")."
            announce(text)
            speak?(text)
        } catch {
            // Soft-fail in live mode; keep running.
            statusMessage = "Live mode on — couldn’t read that frame, trying again…"
        }
    }

    private func announce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: trimmed)
    }

    func speakAgain() {
        guard let narration, !narration.isEmpty else { return }
        speak?(narration)
    }

    func clearNarration() {
        narration = nil
        lastFacts = nil
        statusMessage = isLiveMode ? "Live mode on — watching…" : nil
        errorMessage = nil
        usedModel = false
        liveUpdateCount = 0
    }
}
