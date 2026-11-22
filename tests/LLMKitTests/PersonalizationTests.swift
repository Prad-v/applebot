import XCTest
@testable import LLMKit

final class PersonalizationTests: XCTestCase {
    // MARK: Profile + budget

    func testProfileRenderStaysWithinBudget() throws {
        let profile = PersonalProfile(
            displayName: "Sam",
            roles: ["parent", "engineer"],
            city: "Lisbon",
            replyStyle: .concise,
            boundaries: ["No work talk after 9pm"],
            confirmedPrefs: ["Prefer short replies", "Use metric units"]
        )
        let block = try XCTUnwrap(profile.render(maxTokens: PersonalProfile.promptTokens))
        XCTAssertTrue(block.contains("Sam"))
        XCTAssertTrue(block.contains("Prefer short replies"))
        XCTAssertLessThanOrEqual(TokenEstimator.estimate(block), PersonalProfile.promptTokens + 20)
    }

    func testPendingPreferenceConfirmFlow() {
        var profile = PersonalProfile()
        profile.proposePreference("User preference: short replies")
        XCTAssertEqual(profile.pendingPrefs.count, 1)
        let id = profile.pendingPrefs[0].id
        profile.confirmPreference(id: id)
        XCTAssertTrue(profile.pendingPrefs.isEmpty)
        XCTAssertEqual(profile.confirmedPrefs, ["User preference: short replies"])
    }

    func testPersonalContextBudgetSplitsProfileAndFacts() throws {
        let profile = PersonalProfile(displayName: "Alex", replyStyle: .bullets)
        let facts = (0..<20).map {
            MemoryFact(text: "User remembers item \($0) with enough words to count", category: .other)
        }
        let block = try XCTUnwrap(PersonalContextBudget.render(profile: profile, facts: facts))
        XCTAssertTrue(block.contains("Alex"))
        XCTAssertTrue(block.contains("Things you remember"))
        XCTAssertLessThanOrEqual(TokenEstimator.estimate(block), PersonalContextBudget.totalTokens + 40)
    }

    func testAbsorbIdentityFact() {
        var profile = PersonalProfile()
        profile.absorbIdentityFact(MemoryFact(text: "User's name is Jordan", category: .person))
        profile.absorbIdentityFact(MemoryFact(text: "User lives in / is from Austin", category: .place))
        XCTAssertEqual(profile.displayName, "Jordan")
        XCTAssertEqual(profile.city, "Austin")
    }

    // MARK: Ranked / expiry memory

    func testExpiredFactsDroppedFromRenderUnlessPinned() {
        let now = Date()
        let expired = MemoryFact(
            text: "User mentioned: old interview last month",
            category: .event,
            updatedAt: now.addingTimeInterval(-30 * 86_400),
            expiresAt: now.addingTimeInterval(-86_400)
        )
        let pinnedExpired = MemoryFact(
            text: "User mentioned: keep this event anyway",
            category: .event,
            pinned: true,
            expiresAt: now.addingTimeInterval(-86_400)
        )
        let fresh = MemoryFact(text: "User's name is Sam", category: .person, confidence: 0.9)
        let block = MemoryBudget.render([expired, pinnedExpired, fresh], now: now)
        XCTAssertEqual(block?.contains("old interview"), false)
        XCTAssertTrue(block?.contains("keep this event") == true)
        XCTAssertTrue(block?.contains("Sam") == true)
    }

    func testRankPrefersPinnedAndHighConfidence() {
        let now = Date()
        let low = MemoryFact(text: "User likes tea in the morning hours", category: .preference, confidence: 0.2)
        let high = MemoryFact(text: "User prefers short replies always", category: .preference, confidence: 0.95)
        let pinned = MemoryFact(text: "User's partner is named Avery", category: .person, pinned: true, confidence: 0.5)
        let ranked = MemoryBudget.rank([low, high, pinned], now: now)
        XCTAssertEqual(ranked.first?.text, pinned.text)
        XCTAssertEqual(ranked[1].text, high.text)
    }

    func testMergeSetsDefaultExpiryForEvents() {
        let now = Date()
        let event = MemoryFact(text: "User mentioned: interview next Friday", category: .event, updatedAt: now)
        let merged = MemoryBudget.merge(existing: [], adding: [event], now: now)
        XCTAssertNotNil(merged[0].expiresAt)
    }

    // MARK: Intent router

    func testIntentRouterCalendarAndRewrite() {
        let router = IntentRouter()
        XCTAssertEqual(router.route(question: "What's on my calendar tomorrow?", useDocuments: false), .calendar)
        XCTAssertEqual(router.route(question: "What reminders are due today?", useDocuments: false), .reminders)
        XCTAssertEqual(router.route(question: "rewrite this: hello team", useDocuments: false), .rewrite)
        XCTAssertEqual(router.route(question: "what's the weather in Paris?", useDocuments: false), .liveData)
        XCTAssertEqual(router.route(question: "any emails from Alice?", useDocuments: false), .email)
    }

    func testIntentRouterSkipsDocsWhenEmotional() {
        let router = IntentRouter()
        let emotion = EmotionReading(emotion: .anxiety, intensity: 4)
        let intent = router.route(question: "I feel overwhelmed about work", useDocuments: true, emotion: emotion)
        XCTAssertEqual(intent, .emotional)
        XCTAssertFalse(intent.wantsDocuments)
    }

    func testIntentRouterDocumentsWhenFactualAndEnabled() {
        let router = IntentRouter()
        XCTAssertEqual(router.route(question: "How do I reset the router?", useDocuments: true), .documents)
        XCTAssertEqual(router.route(question: "How do I reset the router?", useDocuments: false), .chat)
    }

    // MARK: Style card

    func testStyleCardExtractDraftAndRequest() {
        let card = StyleCard(samples: ["Hey — quick note."], traits: "warm, short", isEnabled: true)
        XCTAssertTrue(card.isReady)
        let draft = StyleCard.extractDraft(from: "rewrite this: Please find attached the report.")
        XCTAssertEqual(draft, "Please find attached the report.")
        let request = card.rewriteRequest(draft: "rewrite: hello")
        XCTAssertTrue(request.instructions.contains("personal writing voice"))
        XCTAssertTrue(request.prompt.contains("hello"))
    }

    // MARK: Voice note

    func testVoiceNoteStructurerHeuristic() {
        let note = VoiceNoteStructurer.structure(
            "Meeting with design. Ship the onboarding by Friday. Remind me to ping Avery."
        )
        XCTAssertEqual(note.pack, "Voice notes")
        XCTAssertFalse(note.title.isEmpty)
        XCTAssertTrue(note.documentTitle.hasPrefix("Voice notes / "))
        XCTAssertTrue(note.body.contains("•"))
        XCTAssertTrue(note.tags.contains("meeting") || note.tags.contains("todo") || note.tags.contains("voice"))
    }

    func testVoiceNoteParsePolished() {
        let polished = """
        TITLE: Design sync
        BODY: Ship onboarding | Ping Avery
        TAGS: meeting, todo
        """
        let note = VoiceNoteStructurer.parsePolished(polished, fallback: "Meeting notes")
        XCTAssertEqual(note.title, "Design sync")
        XCTAssertTrue(note.body.contains("Ship onboarding"))
        XCTAssertEqual(note.tags, ["meeting", "todo"])
    }

    // MARK: Daily brief

    func testDailyBriefBuilder() {
        let profile = PersonalProfile(displayName: "Sam")
        let facts = [
            MemoryFact(text: "User has an ongoing concern: sleep schedule", category: .openLoop, confidence: 0.8)
        ]
        let start = Date()
        let events = [
            BriefEvent(title: "Design review", start: start.addingTimeInterval(3600), end: start.addingTimeInterval(7200))
        ]
        let brief = DailyBriefBuilder.build(
            profile: profile, facts: facts, events: events,
            reminderTitles: ["Buy milk"], now: start
        )
        XCTAssertTrue(brief.greeting.contains("Sam"))
        XCTAssertTrue(brief.agendaLines.contains(where: { $0.contains("Design review") }))
        XCTAssertTrue(brief.reminderLines.contains("Buy milk"))
        XCTAssertTrue(brief.openLoops.contains(where: { $0.contains("sleep") }))
        XCTAssertTrue(brief.markdown.contains("Today"))
        XCTAssertTrue(brief.markdown.contains("Reminders"))
    }

    // MARK: Pipeline integration

    func testPipelineSkipsRetrievalForChatIntent() async throws {
        let called = RetrievalFlag()
        let engine = MockEngine(scripts: [.reply("Hi!")])
        let pipeline = ChatPipeline(
            engine: engine,
            retriever: { _ in
                await called.mark()
                return []
            }
        )
        var result: ChatResult?
        for try await event in pipeline.send(question: "Hi there", state: ChatState(), useDocuments: true) {
            if case .finished(let finished) = event { result = finished }
        }
        XCTAssertEqual(result?.intent, .chat)
        let wasCalled = await called.value
        XCTAssertFalse(wasCalled)
    }

    func testPipelineRewriteUsesStyleCard() async throws {
        let engine = MockEngine(scripts: [.reply("Hey — quick note.")])
        let card = StyleCard(samples: ["Hey — quick note."], traits: "warm", isEnabled: true)
        let pipeline = ChatPipeline(engine: engine, styleCard: card)
        var result: ChatResult?
        for try await event in pipeline.send(
            question: "rewrite this: Please be advised that the meeting is cancelled.",
            state: ChatState(),
            useDocuments: false
        ) {
            if case .finished(let finished) = event { result = finished }
        }
        XCTAssertEqual(result?.intent, .rewrite)
        XCTAssertEqual(result?.answer, "Hey — quick note.")
        XCTAssertTrue(engine.requests[0].instructions.contains("personal writing voice"))
    }
}

private actor RetrievalFlag {
    private(set) var value = false
    func mark() { value = true }
}
