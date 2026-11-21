import Foundation
import Observation
import AVFoundation
import Speech

/// On-device speech input and spoken replies. Refuses cloud speech recognition.
@MainActor
@Observable
final class VoiceController: NSObject {
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
    /// True when the current locale can do on-device recognition.
    private(set) var onDeviceRecognitionAvailable = false

    var autoSpeak: Bool {
        didSet { defaults.set(autoSpeak, forKey: Keys.autoSpeak) }
    }

    var handsFree: Bool {
        didSet { defaults.set(handsFree, forKey: Keys.handsFree) }
    }

    /// Called with the final transcript when the user finishes a utterance (tap-to-stop or end-of-speech).
    var onUtterance: ((String) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var speakContinuation: CheckedContinuation<Void, Never>?

    enum Keys {
        static let autoSpeak = "voiceAutoSpeak"
        static let handsFree = "voiceHandsFree"
    }

    override init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        if defaults.object(forKey: Keys.autoSpeak) == nil {
            autoSpeak = true
        } else {
            autoSpeak = defaults.bool(forKey: Keys.autoSpeak)
        }
        handsFree = defaults.bool(forKey: Keys.handsFree)
        super.init()
        synthesizer.delegate = self
        refreshOnDeviceAvailability()
    }

    func refreshOnDeviceAvailability() {
        let speech = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        recognizer = speech
        onDeviceRecognitionAvailable = speech?.supportsOnDeviceRecognition == true
    }

    // MARK: - Listening

    func toggleListening() {
        if phase == .listening {
            stopListening(submit: true)
        } else {
            startListening()
        }
    }

    func startListening() {
        errorMessage = nil
        statusMessage = nil
        stopSpeaking()
        refreshOnDeviceAvailability()

        guard onDeviceRecognitionAvailable else {
            errorMessage = "On-device speech recognition is not available for this language. Voice input stays off so nothing is sent to Apple's servers."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition is not available right now."
            return
        }

        requestPermissions { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.errorMessage = "Microphone / speech access is off. Enable it in Settings → Applebot to talk."
                return
            }
            self.beginRecognition(with: recognizer)
        }
    }

    /// Speech + microphone must both be allowed before `installTap` (otherwise AVAudioEngine aborts).
    private func requestPermissions(completion: @escaping @MainActor (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    completion(false)
                    return
                }
                if #available(iOS 17.0, *) {
                    AVAudioApplication.requestRecordPermission { granted in
                        Task { @MainActor in completion(granted) }
                    }
                } else {
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        Task { @MainActor in completion(granted) }
                    }
                }
            }
        }
    }

    private func beginRecognition(with recognizer: SFSpeechRecognizer) {
        // Tear down any previous session without submitting a transcript.
        finishListening(submit: false, invokingCallback: false)

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        // Keep partial results coming on the simulator / when the user pauses briefly.
        if #available(iOS 13, *) {
            request.taskHint = .dictation
        }
        recognitionRequest = request

        let input = audioEngine.inputNode
        // Prefer the hardware input format after the session is active. A 0-rate / 0-channel
        // format makes installTap abort the process.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "Microphone is not ready. On the Simulator, use I/O → Audio Input, or try on a physical iPhone."
            recognitionRequest = nil
            return
        }

        removeTapIfNeeded()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
            teardownAudio()
            return
        }

        transcript = ""
        partialTranscript = ""
        phase = .listening
        statusMessage = "Listening… tap the mic when you are done"

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.partialTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.transcript = result.bestTranscription.formattedString
                        self.finishListening(submit: true)
                    }
                }
                if let error, self.phase == .listening {
                    let ns = error as NSError
                    // 203 = no speech detected, 216/301 = canceled — not user-facing failures.
                    if ![203, 216, 301].contains(ns.code) {
                        self.errorMessage = "Could not hear that. Try again."
                    }
                    self.finishListening(submit: !self.partialTranscript.isEmpty)
                }
            }
        }
    }

    func stopListening(submit: Bool) {
        finishListening(submit: submit)
    }

    private func finishListening(submit: Bool, invokingCallback: Bool = true) {
        guard phase == .listening || recognitionRequest != nil || tapInstalled else { return }
        let text = (transcript.isEmpty ? partialTranscript : transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        teardownAudio()
        phase = .idle
        statusMessage = nil
        transcript = text
        partialTranscript = text
        if invokingCallback, submit, !text.isEmpty {
            onUtterance?(text)
        }
    }

    private func teardownAudio() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeTapIfNeeded()
        // Leave the session alone if TTS may start immediately after.
    }

    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    // MARK: - Speaking

    func speak(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard autoSpeak, !cleaned.isEmpty else { return }
        stopListening(submit: false)
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
        speakContinuation?.resume()
        speakContinuation = nil
    }

    func stopAll() {
        stopListening(submit: false)
        stopSpeaking()
        phase = .idle
        statusMessage = nil
    }

    /// Resume hands-free listening after TTS, if enabled.
    func maybeResumeListening() {
        guard handsFree, phase == .idle, onDeviceRecognitionAvailable else { return }
        startListening()
    }
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.phase = .idle
            self.statusMessage = nil
            self.speakContinuation?.resume()
            self.speakContinuation = nil
            self.maybeResumeListening()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.phase = .idle
            self.statusMessage = nil
            self.speakContinuation?.resume()
            self.speakContinuation = nil
        }
    }
}
