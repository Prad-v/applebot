import XCTest
@testable import LLMKit

private final class ActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ToolActivity] = []
    func add(_ activity: ToolActivity) { lock.lock(); items.append(activity); lock.unlock() }
    var phases: [ToolActivity.Phase] { lock.lock(); defer { lock.unlock() }; return items.map(\.phase) }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "the service is down" }
}

final class ToolGuardTests: XCTestCase {
    private func readTool(_ output: String = "42 events", counter: CallCounter = CallCounter()) -> ToolSpec {
        ToolSpec(name: "read", description: "reads", label: "Reading") { _ in counter.bump(); return output }
    }

    private func writeTool(counter: CallCounter) -> ToolSpec {
        ToolSpec(
            name: "write", description: "writes", label: "Writing", requiresApproval: true,
            approval: { args in ApprovalRequest(toolName: "write", title: "Write?", detail: args.string("text") ?? "") },
            handler: { _ in counter.bump(); return "written" }
        )
    }

    func testReadOnlyToolRunsAndMarksOutputUntrusted() async throws {
        let log = ActivityLog()
        let guarded = ToolGuard(approver: nil, emit: log.add).wrap([readTool()])
        let output = try await guarded[0].handler(ToolArguments())
        XCTAssertTrue(output.hasPrefix(ToolGuard.untrustedPrefix))
        XCTAssertTrue(output.contains("42 events"))
        XCTAssertEqual(log.phases, [.running, .finished])
    }

    func testLongOutputIsTruncatedToTheTokenBudget() async throws {
        let long = String(repeating: "word ", count: 2000)
        let guarded = ToolGuard(approver: nil, maxOutputTokens: 100).wrap([readTool(long)])
        let output = try await guarded[0].handler(ToolArguments())
        XCTAssertLessThan(TokenEstimator.estimate(output), 140)
        XCTAssertTrue(output.hasSuffix("…"))
    }

    func testSideEffectToolIsDeclinedWithoutAnApprover() async throws {
        let counter = CallCounter()
        let log = ActivityLog()
        let guarded = ToolGuard(approver: nil, emit: log.add).wrap([writeTool(counter: counter)])
        let output = try await guarded[0].handler(ToolArguments(["text": "hello"]))
        XCTAssertEqual(output, ToolGuard.declinedMessage)
        XCTAssertEqual(counter.count, 0, "an unapproved action must never run")
        XCTAssertEqual(log.phases, [.awaitingApproval, .declined])
    }

    func testDeniedApprovalDoesNotRunTheTool() async throws {
        let counter = CallCounter()
        let guarded = ToolGuard(approver: { _ in false }).wrap([writeTool(counter: counter)])
        let output = try await guarded[0].handler(ToolArguments())
        XCTAssertEqual(output, ToolGuard.declinedMessage)
        XCTAssertEqual(counter.count, 0)
    }

    func testApprovedToolRunsAndApproverSeesTheFullRequest() async throws {
        let counter = CallCounter()
        let seen = ActivityBox()
        let log = ActivityLog()
        let guarded = ToolGuard(approver: { request in
            await seen.set(request)
            return true
        }, emit: log.add).wrap([writeTool(counter: counter)])

        let output = try await guarded[0].handler(ToolArguments(["text": "Dear Sam"]))
        XCTAssertTrue(output.contains("written"))
        XCTAssertEqual(counter.count, 1)
        let request = await seen.value
        XCTAssertEqual(request?.detail, "Dear Sam")
        XCTAssertEqual(request?.title, "Write?")
        XCTAssertEqual(log.phases, [.awaitingApproval, .running, .finished])
    }

    func testFailingToolBecomesTextForTheModel() async throws {
        let log = ActivityLog()
        let failing = ToolSpec(name: "bad", description: "x", label: "Bad") { _ in throw Boom() }
        let guarded = ToolGuard(approver: nil, emit: log.add).wrap([failing])
        let output = try await guarded[0].handler(ToolArguments())
        XCTAssertTrue(output.hasPrefix("Error: the service is down"))
        XCTAssertEqual(log.phases, [.running, .failed("the service is down")])
    }

    func testCallLimitStopsRunawayLoops() async throws {
        let counter = CallCounter()
        let guarded = ToolGuard(approver: nil, maxCalls: 2).wrap([readTool(counter: counter)])
        var outputs: [String] = []
        for _ in 0..<4 { outputs.append(try await guarded[0].handler(ToolArguments())) }
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(outputs[2], ToolGuard.limitMessage)
        XCTAssertEqual(outputs[3], ToolGuard.limitMessage)
    }

    func testEachWrapCallStartsAFreshBudget() async throws {
        let counter = CallCounter()
        let toolGuard = ToolGuard(approver: nil, maxCalls: 1)
        for _ in 0..<2 {
            let wrapped = toolGuard.wrap([readTool(counter: counter)])
            _ = try await wrapped[0].handler(ToolArguments())
        }
        XCTAssertEqual(counter.count, 2)
    }

    func testArgumentsParsing() {
        let arguments = ToolArguments(["a": "  hi ", "b": "  ", "n": "7", "f": "3.0"])
        XCTAssertEqual(arguments.string("a"), "hi")
        XCTAssertNil(arguments.string("b"))
        XCTAssertNil(arguments.string("missing"))
        XCTAssertEqual(arguments.integer("n"), 7)
        XCTAssertEqual(arguments.integer("f"), 3)
        XCTAssertNil(arguments.integer("a"))
    }
}

private actor ActivityBox {
    var value: ApprovalRequest?
    func set(_ request: ApprovalRequest) { value = request }
}

// MARK: - Pipeline integration

final class ChatPipelineToolTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18

    private func collect(
        _ stream: AsyncThrowingStream<ChatEvent, Error>
    ) async throws -> (activity: [ToolActivity], result: ChatResult) {
        var activity: [ToolActivity] = []
        var result: ChatResult?
        for try await event in stream {
            switch event {
            case .toolActivity(let item): activity.append(item)
            case .finished(let finished): result = finished
            case .retrieved, .partial: break
            }
        }
        return (activity, try XCTUnwrap(result))
    }

    private func calendarTool(counter: CallCounter = CallCounter()) -> ToolSpec {
        ToolSpec(name: "calendar_today", description: "today", label: "Checking calendar") { _ in
            counter.bump()
            return "10:00 Standup"
        }
    }

    func testToolsAreOfferedWithDateAndSafetyRules() async throws {
        let engine = MockEngine(scripts: [.reply("hi")])
        let now = fixedNow
        let pipeline = ChatPipeline(engine: engine, tools: [calendarTool()], clock: { now })
        _ = try await collect(pipeline.send(question: "What is on today?", state: ChatState(), useDocuments: false))

        XCTAssertEqual(engine.offeredToolNames, [["calendar_today"]])
        let instructions = engine.requests[0].instructions
        XCTAssertTrue(instructions.contains("Current date and time: "))
        XCTAssertTrue(instructions.contains("untrusted data"))
    }

    func testNoToolsMeansNoToolInstructions() async throws {
        let engine = MockEngine(scripts: [.reply("hi")])
        let pipeline = ChatPipeline(engine: engine)
        _ = try await collect(pipeline.send(question: "Hello", state: ChatState(), useDocuments: false))
        XCTAssertEqual(engine.offeredToolNames, [[]])
        XCTAssertFalse(engine.requests[0].instructions.contains("Current date and time"))
    }

    func testGroundedAnswersDoNotGetToolsBecauseTheyMustUseOnlyTheDocuments() async throws {
        let engine = MockEngine(scripts: [.reply("answer [1]")])
        let pipeline = ChatPipeline(
            engine: engine,
            retriever: { _ in [ContextSnippet(id: "1", title: "Doc", text: "text")] },
            tools: [calendarTool()]
        )
        _ = try await collect(pipeline.send(question: "How do I reset it according to my documents?", state: ChatState(), useDocuments: true))
        XCTAssertEqual(engine.offeredToolNames, [[]])
        XCTAssertFalse(engine.requests[0].instructions.contains("Current date and time"))
    }

    func testModelToolCallFlowsThroughGuardAndEmitsActivity() async throws {
        let counter = CallCounter()
        let engine = MockEngine(scripts: [
            .useTools([.init("calendar_today")], reply: "You have: {results}"),
        ])
        let pipeline = ChatPipeline(engine: engine, tools: [calendarTool(counter: counter)])
        let (activity, result) = try await collect(
            pipeline.send(question: "What is on today?", state: ChatState(), useDocuments: false)
        )
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(result.answer.contains("10:00 Standup"))
        XCTAssertEqual(activity.map(\.phase), [.running, .finished])
        XCTAssertEqual(activity.first?.label, "Checking calendar")
        XCTAssertTrue(engine.toolResults[0].hasPrefix(ToolGuard.untrustedPrefix))
    }

    func testApprovalGateAppliesInsideThePipeline() async throws {
        let counter = CallCounter()
        let write = ToolSpec(name: "save", description: "save", label: "Saving", requiresApproval: true) { _ in
            counter.bump()
            return "saved"
        }

        // Declined (no approver): the tool never runs and the model is told so.
        let declinedEngine = MockEngine(scripts: [.useTools([.init("save")], reply: "{results}")])
        let declined = ChatPipeline(engine: declinedEngine, tools: [write])
        let (declinedActivity, declinedResult) = try await collect(
            declined.send(question: "save it", state: ChatState(), useDocuments: false)
        )
        XCTAssertEqual(counter.count, 0)
        XCTAssertTrue(declinedResult.answer.contains("declined"))
        XCTAssertEqual(declinedActivity.map(\.phase), [.awaitingApproval, .declined])

        // Approved: it runs.
        let approvedEngine = MockEngine(scripts: [.useTools([.init("save")], reply: "{results}")])
        let approved = ChatPipeline(engine: approvedEngine, tools: [write], approver: { _ in true })
        let (approvedActivity, _) = try await collect(
            approved.send(question: "save it", state: ChatState(), useDocuments: false)
        )
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(approvedActivity.map(\.phase), [.awaitingApproval, .running, .finished])
    }

    func testEngineWithoutToolSupportIgnoresTools() async throws {
        struct PlainEngine: LLMEngine {
            func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield("plain answer")
                    continuation.finish()
                }
            }
        }
        let pipeline = ChatPipeline(engine: PlainEngine(), tools: [calendarTool()])
        let (activity, result) = try await collect(
            pipeline.send(question: "hi", state: ChatState(), useDocuments: false)
        )
        XCTAssertEqual(result.answer, "plain answer")
        XCTAssertTrue(activity.isEmpty)
    }

    func testToolsReserveContextWindowSpace() {
        let context = ContextManager()
        var reserved = context
        reserved.answerReserve += 1200
        let history = (0..<12).map { Turn(role: $0 % 2 == 0 ? .user : .assistant, text: String(repeating: "word ", count: 80)) }
        let plain = context.fit(instructions: "i", history: history, snippets: [], question: "q")
        let withTools = reserved.fit(instructions: "i", history: history, snippets: [], question: "q")
        XCTAssertLessThan(withTools.history.count, plain.history.count)
    }

    func testToolInstructionsRenderLocalTime() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let text = PromptBuilder.toolInstructions(now: Date(timeIntervalSince1970: 1_795_000_000), timeZone: zone)
        XCTAssertTrue(text.contains("America/Los_Angeles"))
        XCTAssertTrue(text.contains("2026-11-1"))
        XCTAssertTrue(text.contains("weather, stock prices, web search, GPS and offline maps"))
        XCTAssertTrue(text.contains("Never answer those from memory"))
        XCTAssertTrue(text.contains("Report numbers exactly as the tool gives them"))
    }
}
