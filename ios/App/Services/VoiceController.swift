import Foundation
import Observation
import AVFoundation
import Speech
import UIKit
import os

/// On-device speech input and spoken replies.
///
/// Listening uses **file-based** recognition (`AVAudioRecorder` → `SFSpeechURLRecognitionRequest`)
/// instead of `AVAudioEngine.installTap`, which aborts the process when the mic format is invalid
/// (a common Simulator / session-timing failure that cannot be caught in Swift).
@MainActor
@Observable
final class VoiceController {
    enum Phase: String {
        case idle
        case listening
        case speaking
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var partialTranscript = ""
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var errorEpoch: Int = 0
    private(set) var onDeviceRecognitionAvailable = false
    private(set) var speechAuthDescription = "Not asked yet"
    private(set) var micAuthDescription = "Not asked yet"

    var autoSpeak: Bool {
        didSet { defaults.set(autoSpeak, forKey: Keys.autoSpeak) }
    }

    var handsFree: Bool {
        didSet { defaults.set(handsFree, forKey: Keys.handsFree) }
    }

    var onUtterance: ((String) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let ttsDelegate = SpeechSynthesizerProxy()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "dev.kekaflow.applebot", category: "voice")

    enum Keys {
        static let autoSpeak = "voiceAutoSpeak"
        static let handsFree = "voiceHandsFree"
    }

    init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        if defaults.object(forKey: Keys.autoSpeak) == nil {
            autoSpeak = true
        } else {
            autoSpeak = defaults.bool(forKey: Keys.autoSpeak)
        }
        handsFree = defaults.bool(forKey: Keys.handsFree)
        ttsDelegate.owner = self
        synthesizer.delegate = ttsDelegate
        refreshOnDeviceAvailability()
        refreshAuthDescriptions()
    }

    func refreshOnDeviceAvailability() {
        let speech = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        recognizer = speech
        onDeviceRecognitionAvailable = speech?.supportsOnDeviceRecognition == true
        refreshAuthDescriptions()
    }

    func refreshAuthDescriptions() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: speechAuthDescription = "Not asked yet"
        case .denied: speechAuthDescription = "Denied"
        case .restricted: speechAuthDescription = "Restricted"
        case .authorized: speechAuthDescription = "Allowed"
        @unknown default: speechAuthDescription = "Unknown"
        }

        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined: micAuthDescription = "Not asked yet"
            case .denied: micAuthDescription = "Denied"
            case .granted: micAuthDescription = "Allowed"
            @unknown default: micAuthDescription = "Unknown"
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .undetermined: micAuthDescription = "Not asked yet"
            case .denied: micAuthDescription = "Denied"
            case .granted: micAuthDescription = "Allowed"
            @unknown default: micAuthDescription = "Unknown"
            }
        }
    }

    // MARK: - Listening (tap to start, tap to stop → transcribe file)

    func toggleListening() {
        if phase == .listening {
            stopListening(submit: true)
        } else {
            startListening()
        }
    }

    func startListening() {
        errorMessage = nil
        statusMessage = "Checking microphone access…"
        stopSpeaking()
        listenTask?.cancel()

        listenTask = Task { @MainActor in
            let permitted = await ensurePermissions()
            guard !Task.isCancelled else { return }
            refreshAuthDescriptions()
            refreshOnDeviceAvailability()

            guard permitted.speech else {
                fail(speechSettingsMessage())
                return
            }
            guard permitted.mic else {
                fail("Microphone access is off. Enable Microphone for Applebot in iOS Settings, then try again.")
                return
            }
            #if !targetEnvironment(simulator)
            guard onDeviceRecognitionAvailable else {
                fail(
                    "On-device speech recognition is not available for \(Locale.current.identifier). "
                        + "Voice input stays off so audio is never sent to Apple's servers."
                )
                return
            }
            #endif
            guard recognizer?.isAvailable == true else {
                fail("Speech recognition is not available right now.")
                return
            }

            do {
                try beginRecording()
            } catch {
                fail("Could not start the microphone: \(error.localizedDescription)")
            }
        }
    }

    func stopListening(submit: Bool) {
        listenTask?.cancel()
        listenTask = nil
        guard phase == .listening || recorder != nil else { return }

        let url = endRecording()
        phase = .idle
        statusMessage = submit ? "Transcribing…" : nil

        guard submit, let url else {
            statusMessage = nil
            return
        }

        listenTask = Task { @MainActor in
            do {
                let text = try await transcribe(fileURL: url)
                try? FileManager.default.removeItem(at: url)
                guard !Task.isCancelled else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                transcript = trimmed
                partialTranscript = trimmed
                statusMessage = nil
                if trimmed.isEmpty {
                    fail("I didn't catch that. Tap the mic and try again.")
                } else {
                    onUtterance?(trimmed)
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                guard !Task.isCancelled else { return }
                fail("Could not transcribe: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Permissions

    private func ensurePermissions() async -> (speech: Bool, mic: Bool) {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let finish: (SFSpeechRecognizerAuthorizationStatus) -> Void = { status in
                cont.resume(returning: status == .authorized)
            }
            switch SFSpeechRecognizer.authorizationStatus() {
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization(finish)
            default:
                finish(SFSpeechRecognizer.authorizationStatus())
            }
        }
        guard speech else { return (false, false) }

        let mic = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if #available(iOS 17.0, *) {
                switch AVAudioApplication.shared.recordPermission {
                case .granted: cont.resume(returning: true)
                case .denied: cont.resume(returning: false)
                case .undetermined, _:
                    AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
                }
            } else {
                switch AVAudioSession.sharedInstance().recordPermission {
                case .granted: cont.resume(returning: true)
                case .denied: cont.resume(returning: false)
                case .undetermined, _:
                    AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
                }
            }
        }
        return (true, mic)
    }

    private func speechSettingsMessage() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return "Speech Recognition is off for Applebot. Enable it in iOS Settings → Applebot, then try again."
        default:
            return "Speech Recognition permission is required to use the mic."
        }
    }

    private func fail(_ message: String) {
        log.error("voice failure: \(message, privacy: .public)")
        _ = endRecording()
        statusMessage = nil
        errorMessage = message
        errorEpoch += 1
        phase = .idle
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Record / transcribe (no installTap)

    private func beginRecording() throws {
        _ = endRecording()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebot-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw NSError(
                domain: "Applebot.Voice", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Recorder failed to start."]
            )
        }

        self.recorder = recorder
        self.recordingURL = url
        transcript = ""
        partialTranscript = ""
        phase = .listening
        statusMessage = "Listening… tap the mic again when you finish"
        errorMessage = nil
        log.info("recording to \(url.lastPathComponent, privacy: .public)")
    }

    private func endRecording() -> URL? {
        let url = recordingURL
        if let recorder {
            if recorder.isRecording {
                recorder.stop()
            }
        }
        recorder = nil
        recordingURL = nil
        return url
    }

    private func transcribe(fileURL: URL) async throws -> String {
        guard let recognizer else {
            throw NSError(domain: "Applebot.Voice", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No speech recognizer."])
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        #if targetEnvironment(simulator)
        request.requiresOnDeviceRecognition = false
        #else
        request.requiresOnDeviceRecognition = true
        #endif
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { cont in
            var settled = false
            recognizer.recognitionTask(with: request) { result, error in
                if settled { return }
                if let error {
                    settled = true
                    cont.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                settled = true
                cont.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }

    // MARK: - Speaking

    func speak(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard autoSpeak, !cleaned.isEmpty else { return }
        if phase == .listening {
            stopListening(submit: false)
        }
        stopSpeaking()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.05
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")

        phase = .speaking
        statusMessage = "Speaking…"
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if phase == .speaking {
            phase = .idle
            statusMessage = nil
        }
    }

    func stopAll() {
        listenTask?.cancel()
        listenTask = nil
        stopListening(submit: false)
        stopSpeaking()
        phase = .idle
        statusMessage = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func maybeResumeListening() {
        guard handsFree, phase == .idle else { return }
        #if !targetEnvironment(simulator)
        guard onDeviceRecognitionAvailable else { return }
        #endif
        startListening()
    }

    fileprivate func speechDidFinish() {
        phase = .idle
        statusMessage = nil
        maybeResumeListening()
    }

    fileprivate func speechDidCancel() {
        phase = .idle
        statusMessage = nil
    }
}

private final class SpeechSynthesizerProxy: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    weak var owner: VoiceController?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.owner?.speechDidFinish() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.owner?.speechDidCancel() }
    }
}
