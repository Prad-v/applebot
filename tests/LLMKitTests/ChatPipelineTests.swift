import XCTest
@testable import LLMKit

final class ChatPipelineTests: XCTestCase {
    private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> (partials: [String], result: ChatResult) {
        var partials: [String] = []
        var result: ChatResult?
        for try await event in stream {
            switch event {
            case .partial(let text): partials.append(text)
            case .finished(let finished): result = finished
            case .retrieved, .toolActivity: break
            }
        }
        return (partials, try XCTUnwrap(result))
    }

    func testStreamsCumulativeTextAndAppendsHistory() async throws {
        let engine = MockEngine(scripts: [.reply("Hello there!")], chunkSize: 4)
        let pipeline = ChatPipeline(engine: engine)
        let (partials, result) = try await collect(
            pipeline.send(question: "Hi", state: ChatState(), useDocuments: false)
        )
        XCTAssertEqual(partials.last, "Hello there!")
        XCTAssertEqual(partials.first, "Hell")
        XCTAssertEqual(result.answer, "Hello there!")
        XCTAssertEqual(result.state.history, [Turn(role: .user, text: "Hi"), Turn(role: .assistant, text: "Hello there!")])
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertFalse(engine.requests[0].instructions.contains("ONLY the numbered context"))
    }

    func testGroundedAnswerResolvesCitations() async throws {
        let snippets = [
            ContextSnippet(id: "1", title: "Manual", text: "Hold reset for ten seconds."),
            ContextSnippet(id: "2", title: "Notes", text: "Unrelated."),
        ]
        let engine = MockEngine(scripts: [.reply("Hold the button for ten seconds [1].")])
        let pipeline = ChatPipeline(engine: engine, retriever: { _ in snippets })
        let (_, result) = try await collect(
            pipeline.send(question: "How to reset?", state: ChatState(), useDocuments: true)
        )
        XCTAssertEqual(result.citedIndices, [1])
        XCTAssertEqual(result.citedSnippets.map(\.title), ["Manual"])
        XCTAssertFalse(result.notFound)
        XCTAssertTrue(engine.requests[0].prompt.contains("[1] Manual"))
        XCTAssertTrue(engine.requests[0].instructions.contains("ONLY the numbered context"))
    }

    func testNotFoundIsDetected() async throws {
        let engine = MockEngine(scripts: [.reply(PromptBuilder.notFoundPhrase)])
        let pipeline = ChatPipeline(engine: engine, retriever: { _ in [] })
        let (_, result) = try await collect(
            pipeline.send(question: "Who won?", state: ChatState(), useDocuments: true)
        )
        XCTAssertTrue(result.notFound)
        XCTAssertTrue(result.citedIndices.isEmpty)
    }

    func testDocumentsDisabledSkipsRetrieval() async throws {
        let called = Flag()
        let engine = MockEngine(scripts: [.reply("ok")])
        let pipeline = ChatPipeline(engine: engine, retriever: { _ in await called.set(); return [] })
        _ = try await collect(pipeline.send(question: "hi", state: ChatState(), useDocuments: false))
        let wasCalled = await called.value
        XCTAssertFalse(wasCalled)
    }

    func testFollowUpIsRewrittenForRetrieval() async throws {
        let captured = Box()
        let engine = MockEngine(scripts: [.reply("reset button location"), .reply("Answer [1]")])
        let pipeline = ChatPipeline(engine: engine, retriever: { query in
            await captured.set(query)
            return [ContextSnippet(id: "x", title: "T", text: "body")]
        })
        let state = ChatState(history: [
            Turn(role: .user, text: "Tell me about the router"),
            Turn(role: .assistant, text: "It is the Aurora X2."),
        ])
        let (_, result) = try await collect(pipeline.send(question: "where is the button?", state: state, useDocuments: true))
        let query = await captured.value
        XCTAssertEqual(query, "reset button location")
        XCTAssertEqual(result.searchQuery, "reset button location")
        XCTAssertEqual(engine.requests.count, 2)
    }

    func testOverflowTriggersRetryWithTighterBudget() async throws {
        let engine = MockEngine(scripts: [.fail(.contextOverflow), .reply("recovered [1]")])
        let big = (0..<8).map {
            ContextSnippet(id: "\($0)", title: "Doc", text: String(repeating: "lorem ipsum dolor ", count: 120))
        }
        let pipeline = ChatPipeline(engine: engine, retriever: { _ in big })
        let (_, result) = try await collect(pipeline.send(question: "q", state: ChatState(), useDocuments: true))
        XCTAssertEqual(result.answer, "recovered [1]")
        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertLessThanOrEqual(engine.requests[1].prompt.count, engine.requests[0].prompt.count)
    }

    func testGroundedAnswerWithoutCitationsTriggersOneRetry() async throws {
        let snippets = [ContextSnippet(id: "1", title: "Manual", text: "Hold reset for ten seconds.")]
        let engine = MockEngine(scripts: [
            .reply("Just hold the button."),
            .reply("Hold reset for ten seconds [1]."),
        ])
        let pipeline = ChatPipeline(engine: engine, retriever: { _ in snippets })
        let (_, result) = try await collect(
            pipeline.send(question: "How to reset?", state: ChatState(), useDocuments: true)
        )
        XCTAssertEqual(result.answer, "Hold reset for ten seconds [1].")
        XCTAssertEqual(result.citedIndices, [1])
        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertTrue(engine.requests[1].instructions.contains(PromptBuilder.groundingRetryNote))
        XCTAssertEqual(engine.requests[0].temperature, 0.2)
        XCTAssertEqual(engine.requests[0].maximumResponseTokens, 550)
    }

    func testGroundedEmptyContextWithoutNotFoundTriggersRetry() async throws {
        let engine = MockEngine(scripts: [
            .reply("Probably Tuesday."),
            .reply(PromptBuilder.notFoundPhrase),
        ])
        let pipeline = ChatPipeline(engine: engine, retriever: { _ in [] })
        let (_, result) = try await collect(
            pipeline.send(question: "When is payday according to my documents?", state: ChatState(), useDocuments: true)
        )
        XCTAssertTrue(result.notFound)
        XCTAssertEqual(engine.requests.count, 2)
    }

    func testPersistentOverflowSurfacesError() async {
        let engine = MockEngine(scripts: [.fail(.contextOverflow), .fail(.contextOverflow), .fail(.contextOverflow)])
        let pipeline = ChatPipeline(engine: engine)
        do {
            _ = try await collect(pipeline.send(question: "q", state: ChatState(), useDocuments: false))
            XCTFail("expected overflow")
        } catch {
            XCTAssertEqual(error as? LLMEngineError, .contextOverflow)
        }
    }

    func testGuardrailErrorIsNotRetried() async {
        let engine = MockEngine(scripts: [.fail(.guardrail)])
        let pipeline = ChatPipeline(engine: engine)
        do {
            _ = try await collect(pipeline.send(question: "q", state: ChatState(), useDocuments: false))
            XCTFail("expected guardrail error")
        } catch {
            XCTAssertEqual(error as? LLMEngineError, .guardrail)
            XCTAssertEqual(engine.requests.count, 1)
        }
    }

    func testLongHistoryIsCompactedIntoSummary() async throws {
        let filler = Array(repeating: "word", count: 80).joined(separator: " ")
        let history = (0..<12).flatMap { index in
            [Turn(role: .user, text: "q\(index) \(filler)"), Turn(role: .assistant, text: "a\(index) \(filler)")]
        }
        // First call is the summariser, second is the real answer.
        let engine = MockEngine(scripts: [.reply("They discussed many words."), .reply("final answer")])
        let pipeline = ChatPipeline(engine: engine)
        let (_, result) = try await collect(
            pipeline.send(question: "next?", state: ChatState(history: history), useDocuments: false)
        )
        XCTAssertGreaterThanOrEqual(result.compactions, 1)
        XCTAssertEqual(result.state.summary, "They discussed many words.")
        XCTAssertLessThan(result.state.history.count, history.count + 2)
        XCTAssertTrue(engine.requests.last?.instructions.contains("They discussed many words.") == true)
        XCTAssertEqual(result.answer, "final answer")
    }

    func testSummaryFallbackWhenSummariserFails() async throws {
        let filler = Array(repeating: "word", count: 80).joined(separator: " ")
        let history = (0..<12).flatMap { index in
            [Turn(role: .user, text: "q\(index) \(filler)"), Turn(role: .assistant, text: "a\(index) \(filler)")]
        }
        let engine = MockEngine(scripts: [.fail(.other("boom")), .reply("fine")])
        let pipeline = ChatPipeline(engine: engine)
        let (_, result) = try await collect(
            pipeline.send(question: "next?", state: ChatState(history: history), useDocuments: false)
        )
        XCTAssertEqual(result.answer, "fine")
        XCTAssertNotNil(result.state.summary)
    }

    func testAvailabilityIsExposed() {
        let engine = MockEngine(availability: .appleIntelligenceDisabled)
        XCTAssertEqual(engine.availability(), .appleIntelligenceDisabled)
        XCTAssertFalse(engine.availability().isAvailable)
        XCTAssertFalse(EngineAvailability.deviceNotEligible.message.isEmpty)
    }
}

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}

private actor Box {
    private(set) var value: String?
    func set(_ newValue: String) { value = newValue }
}
