#if canImport(FoundationModels)
import XCTest
import FoundationModels
@testable import LLMKit

/// Apple-only: verifies availability mapping and error translation without needing the model.
/// A live generation is only attempted when Apple Intelligence is actually available.
@available(iOS 26.0, macOS 26.0, *)
final class AppleFMEngineTests: XCTestCase {
    func testAvailabilityMapsToKnownCase() {
        let status = AppleFMEngine().availability()
        switch status {
        case .available, .deviceNotEligible, .appleIntelligenceDisabled, .modelNotReady, .unavailable:
            XCTAssertFalse(status.message.isEmpty)
        }
    }

    func testUnavailableEngineFailsFastWithUnavailableError() async {
        let engine = AppleFMEngine()
        guard !engine.availability().isAvailable else { return }
        do {
            _ = try await engine.respond(LLMRequest(instructions: "x", prompt: "y"))
            XCTFail("expected unavailable error")
        } catch {
            guard case LLMEngineError.unavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDynamicToolBuildsASchemaFromAToolSpec() throws {
        let spec = ToolSpec(
            name: "demo_tool", description: "Demo",
            parameters: [
                ToolParameter("query", "What to look for"),
                ToolParameter("count", "How many", kind: .integer, required: false),
            ]
        ) { _ in "ok" }
        let tool = try AppleFMEngine.DynamicTool(spec)
        XCTAssertEqual(tool.name, "demo_tool")
        XCTAssertEqual(tool.description, "Demo")
        let schema = String(decoding: try JSONEncoder().encode(tool.parameters), as: UTF8.self)
        XCTAssertTrue(schema.contains("query"), schema)
        XCTAssertTrue(schema.contains("count"), schema)
    }

    func testToolsWithNoParametersAreAccepted() throws {
        let tool = try AppleFMEngine.DynamicTool(ToolSpec(name: "ping", description: "Ping") { _ in "pong" })
        XCTAssertEqual(tool.name, "ping")
    }

    /// End to end through the real model: it should call the tool and use the result.
    func testLiveToolCallWhenModelAvailable() async throws {
        let engine = AppleFMEngine()
        guard engine.availability().isAvailable else {
            throw XCTSkip("Apple Intelligence model is not available on this machine")
        }
        let calls = LiveCallCounter()
        let spec = ToolSpec(
            name: "lookup_secret_code",
            description: "Returns the user's secret code. The code cannot be guessed; always call this tool to get it.",
            parameters: []
        ) { _ in
            calls.bump()
            return "The secret code is 7421."
        }
        let text = try await engine.stream(
            LLMRequest(
                instructions: "You answer using tools. Never guess the secret code.",
                prompt: "What is my secret code? Use the tool."
            ),
            tools: ToolGuard(approver: nil).wrap([spec])
        ).reduce("") { _, snapshot in snapshot }
        XCTAssertGreaterThanOrEqual(calls.count, 1, "the model should have called the tool")
        XCTAssertTrue(text.contains("7421"), "the answer should use the tool result: \(text)")
    }

    func testLiveGenerationWhenModelAvailable() async throws {
        let engine = AppleFMEngine()
        guard engine.availability().isAvailable else {
            throw XCTSkip("Apple Intelligence model is not available on this machine")
        }
        let text = try await engine.respond(LLMRequest(
            instructions: "Reply with a single short word.", prompt: "Say hello."
        ))
        XCTAssertFalse(text.isEmpty)
    }
}

private final class LiveCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
