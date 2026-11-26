import XCTest
@testable import LLMKit

final class CompanionTests: XCTestCase {
    private let detector = LexiconEmotionDetector()

    // MARK: - Emotion detection

    func testDetectsEachEmotion() {
        XCTAssertEqual(detector.read("I feel so sad and lonely tonight").emotion, .sadness)
        XCTAssertEqual(detector.read("I'm really anxious about tomorrow").emotion, .anxiety)
        XCTAssertEqual(detector.read("I'm furious with my landlord").emotion, .anger)
        XCTAssertEqual(detector.read("I'm so excited, I got the job!").emotion, .joy)
    }

    func testPlainQuestionsAreNeutral() {
        XCTAssertEqual(detector.read("How does Wi-Fi work?"), .neutral)
        XCTAssertEqual(detector.read("I lost my keys, where should I look?"), .neutral)
        XCTAssertEqual(detector.read("I passed the exam"), .neutral)
        XCTAssertEqual(detector.read(""), .neutral)
    }

    func testIntensityGrowsWithEmphasisAndRepetition() {
        let mild = detector.read("I'm sad")
        let strong = detector.read("I'm so sad and hopeless and I can't stop crying")
        XCTAssertLessThan(mild.intensity, strong.intensity)
        XCTAssertGreaterThanOrEqual(strong.intensity, 4)
        XCTAssertLessThanOrEqual(strong.intensity, 5)
        XCTAssertGreaterThan(detector.read("I'm SO ANGRY!!").intensity, detector.read("i'm angry").intensity)
    }

    func testNegationCancelsOrSoftens() {
        XCTAssertEqual(detector.read("I'm not worried about it"), .neutral)
        XCTAssertEqual(detector.read("I'm not happy about this").emotion, .sadness)
    }

    func testPhrasesAndWordBoundaries() {
        XCTAssertEqual(detector.read("My grandmother passed away last week").emotion, .sadness)
        // "mad" must not match inside "made".
        XCTAssertEqual(detector.read("Can you summarize what I made yesterday?"), .neutral)
    }

    func testReadingClampsIntensityAndNeutralHasNone() {
        XCTAssertEqual(EmotionReading(emotion: .joy, intensity: 99).intensity, 5)
        XCTAssertEqual(EmotionReading(emotion: .joy, intensity: -3).intensity, 1)
        XCTAssertEqual(EmotionReading(emotion: .neutral, intensity: 4).intensity, 0)
        XCTAssertNil(EmotionReading.neutral.guidance)
    }

    func testNeedsSupportOnlyForStrongDistress() {
        XCTAssertTrue(EmotionReading(emotion: .sadness, intensity: 3).needsSupport)
        XCTAssertFalse(EmotionReading(emotion: .sadness, intensity: 2).needsSupport)
        XCTAssertFalse(EmotionReading(emotion: .joy, intensity: 5).needsSupport)
    }

    // MARK: - Prompt building

    func testNeutralToneKeepsOriginalPersonaAndIgnoresEmotion() {
        let builder = PromptBuilder()
        XCTAssertEqual(builder.persona, PromptBuilder.defaultPersona)
        let text = builder.instructions(
            summary: nil, grounded: false, emotion: EmotionReading(emotion: .sadness, intensity: 4)
        )
        XCTAssertEqual(text, PromptBuilder.defaultPersona)
    }

    func testWarmToneAddsPersonaAndEmotionGuidance() {
        let builder = PromptBuilder(tone: .warm)
        XCTAssertTrue(builder.persona.contains("warm and caring companion"))
        XCTAssertTrue(builder.persona.contains("crisis line"))
        XCTAssertTrue(builder.persona.contains("How are you feeling today?"))
        XCTAssertTrue(builder.persona.contains("Never say"))
        XCTAssertTrue(builder.persona.contains("I don't have personal feelings"))
        let text = builder.instructions(
            summary: nil, grounded: false, emotion: EmotionReading(emotion: .anxiety, intensity: 4)
        )
        XCTAssertTrue(text.contains("anxious"))
        XCTAssertTrue(text.contains("Keep the reply short"))
    }

    func testAskingAboutBotCueAddsGuidance() {
        let text = PromptBuilder(tone: .warm).instructions(
            summary: nil, grounded: false, cue: .askingAboutBot
        )
        XCTAssertTrue(text.contains("checking in on you"))
        XCTAssertTrue(text.contains("first person"))
        // Neutral tone ignores the cue.
        let neutral = PromptBuilder(tone: .neutral).instructions(
            summary: nil, grounded: false, cue: .askingAboutBot
        )
        XCTAssertFalse(neutral.contains("checking in on you"))
    }

    func testCompanionCueDetection() {
        XCTAssertEqual(CompanionCue.detect(in: "How are you feeling today?"), .askingAboutBot)
        XCTAssertEqual(CompanionCue.detect(in: "how are you?"), .askingAboutBot)
        XCTAssertEqual(CompanionCue.detect(in: "Do you ever get lonely?"), .askingAboutBot)
        XCTAssertEqual(CompanionCue.detect(in: "are you okay"), .askingAboutBot)
        XCTAssertEqual(CompanionCue.detect(in: "How are you supposed to reset the router?"), .none)
        XCTAssertEqual(CompanionCue.detect(in: "How does Wi-Fi work?"), .none)
        XCTAssertEqual(CompanionCue.detect(in: ""), .none)
    }

    func testExplicitPersonaOverridesTone() {
        XCTAssertEqual(PromptBuilder(persona: "Custom", tone: .warm).persona, "Custom")
    }

    func testEveryToneHasLabelsAndPersona() {
        for tone in ChatTone.allCases {
            XCTAssertFalse(tone.displayName.isEmpty)
            XCTAssertFalse(tone.summary.isEmpty)
            XCTAssertFalse(tone.persona.isEmpty)
        }
        XCTAssertFalse(ChatTone.neutral.isEmotionAware)
        XCTAssertEqual(ChatTone(rawValue: "warm"), .warm)
        XCTAssertEqual(ChatTone.productDefault, .warm)
        XCTAssertEqual(ChatTone.warm.samplingTemperature, 0.75)
        XCTAssertEqual(ChatTone.warm.samplingTemperature(grounded: true, intent: .documents), 0.35)
        XCTAssertEqual(ChatTone.neutral.samplingTemperature(grounded: true, intent: .documents), 0.2)
        XCTAssertNil(ChatTone.neutral.samplingTemperature)
        XCTAssertEqual(ChatTone.warm.maximumResponseTokens(grounded: false, intent: .emotional), 220)
        XCTAssertEqual(ChatTone.warm.maximumResponseTokens(grounded: true, intent: .documents), 550)
        XCTAssertFalse(ChatTone.warm.compactPersona.contains("How are you feeling today?"))
        XCTAssertTrue(ChatTone.warm.persona.contains("How are you feeling today?"))
    }

    func testGuardrailMessageIsKind() {
        let message = LLMEngineError.guardrail.errorDescription ?? ""
        XCTAssertFalse(message.contains("declined"))
        XCTAssertTrue(message.contains("put it another way"))
    }

    // MARK: - Pipeline

    private func run(
        _ question: String, tone: ChatTone, useDocuments: Bool = false,
        retriever: SnippetRetriever? = nil, engine: MockEngine
    ) async throws -> ChatResult {
        let pipeline = ChatPipeline(engine: engine, prompts: PromptBuilder(tone: tone), retriever: retriever)
        var result: ChatResult?
        for try await event in pipeline.send(question: question, state: ChatState(), useDocuments: useDocuments) {
            if case .finished(let finished) = event { result = finished }
        }
        return try XCTUnwrap(result)
    }

    func testWarmPipelineAdaptsInstructionsToMood() async throws {
        let engine = MockEngine(scripts: [.reply("That sounds really hard.")])
        let result = try await run("I feel so sad today", tone: .warm, engine: engine)
        XCTAssertEqual(result.emotion?.emotion, .sadness)
        XCTAssertTrue(engine.requests[0].instructions.contains("warm and caring companion"))
        XCTAssertTrue(engine.requests[0].instructions.contains("The user seems sad"))
    }

    func testNeutralPipelineDoesNotReadEmotion() async throws {
        let engine = MockEngine(scripts: [.reply("ok")])
        let result = try await run("I feel so sad today", tone: .neutral, engine: engine)
        XCTAssertNil(result.emotion)
        XCTAssertFalse(engine.requests[0].instructions.contains("seems sad"))
    }

    func testDistressedUserSkipsDocumentRetrieval() async throws {
        let snippets = [ContextSnippet(id: "1", title: "Notes", text: "Unrelated.")]
        let engine = MockEngine(scripts: [.reply("I'm here with you.")])
        let result = try await run(
            "I'm so sad and hopeless right now", tone: .warm, useDocuments: true,
            retriever: { _ in snippets }, engine: engine
        )
        XCTAssertTrue(result.snippets.isEmpty)
        XCTAssertFalse(engine.requests[0].instructions.contains("ONLY the numbered context"))
        XCTAssertFalse(result.notFound)
    }

    func testCalmQuestionStillUsesDocumentsInWarmTone() async throws {
        let snippets = [ContextSnippet(id: "1", title: "Manual", text: "Hold reset for ten seconds.")]
        let engine = MockEngine(scripts: [.reply("Hold it for ten seconds [1].")])
        let result = try await run(
            "How do I reset it?", tone: .warm, useDocuments: true,
            retriever: { _ in snippets }, engine: engine
        )
        XCTAssertEqual(result.citedIndices, [1])
        XCTAssertTrue(engine.requests[0].instructions.contains("ONLY the numbered context"))
    }

    func testAskingHowAreYouSkipsDocumentsAndInjectsCue() async throws {
        let snippets = [ContextSnippet(id: "1", title: "Notes", text: "Unrelated.")]
        let engine = MockEngine(scripts: [.reply("I'm in a soft mood today. How are you?")])
        let result = try await run(
            "How are you feeling today?", tone: .warm, useDocuments: true,
            retriever: { _ in snippets }, engine: engine
        )
        XCTAssertEqual(result.cue, .askingAboutBot)
        XCTAssertTrue(result.snippets.isEmpty)
        XCTAssertTrue(engine.requests[0].instructions.contains("checking in on you"))
        XCTAssertEqual(engine.requests[0].temperature, 0.75)
        XCTAssertEqual(engine.requests[0].maximumResponseTokens, 220)
        XCTAssertFalse(engine.requests[0].instructions.contains("ONLY the numbered context"))
    }

    func testNeutralToneIgnoresHowAreYouCue() async throws {
        let engine = MockEngine(scripts: [.reply("ok")])
        let result = try await run("How are you feeling today?", tone: .neutral, engine: engine)
        XCTAssertEqual(result.cue, .none)
        XCTAssertNil(engine.requests[0].temperature)
        XCTAssertFalse(engine.requests[0].instructions.contains("checking in on you"))
    }
}
