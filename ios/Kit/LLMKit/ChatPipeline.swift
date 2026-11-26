import Foundation

/// Conversation state carried between turns (persisted by the app).
public struct ChatState: Sendable, Equatable {
    public var summary: String?
    public var history: [Turn]

    public init(summary: String? = nil, history: [Turn] = []) {
        self.summary = summary
        self.history = history
    }
}

/// Final outcome of one question/answer exchange.
public struct ChatResult: Sendable, Equatable {
    public var answer: String
    /// Snippets that were placed in the prompt, in citation order ([1] = first).
    public var snippets: [ContextSnippet]
    /// 1-based indices from `snippets` that the answer cited.
    public var citedIndices: [Int]
    /// True when grounded mode was on and the model said the documents do not contain the answer.
    public var notFound: Bool
    /// The standalone query used for retrieval, if retrieval ran.
    public var searchQuery: String?
    /// New state to persist (history now includes this exchange).
    public var state: ChatState
    /// Number of times the context had to be compacted for this request.
    public var compactions: Int
    /// The emotion read from the user's message (only for emotion-aware tones).
    public var emotion: EmotionReading?
    /// Companion conversational cue (e.g. the user asked how the bot is feeling).
    public var cue: CompanionCue
    /// Local intent classification used to skip RAG / tools when unneeded.
    public var intent: ChatIntent

    public var citedSnippets: [ContextSnippet] {
        citedIndices.compactMap { $0 >= 1 && $0 <= snippets.count ? snippets[$0 - 1] : nil }
    }
}

public enum ChatEvent: Sendable, Equatable {
    /// Retrieval finished (may be empty).
    case retrieved([ContextSnippet])
    /// Cumulative answer text so far.
    case partial(String)
    /// A connector tool is running, waiting for approval, or just finished.
    case toolActivity(ToolActivity)
    /// The exchange completed.
    case finished(ChatResult)
}

/// Retrieval hook: takes a standalone query, returns ranked snippets (best first).
public typealias SnippetRetriever = @Sendable (String) async throws -> [ContextSnippet]

/// Orchestrates one chat turn: optional retrieval, context budgeting, rolling summary
/// compaction, streaming, and recovery from context-window overflow.
public struct ChatPipeline: Sendable {
    public var engine: any LLMEngine
    public var context: ContextManager
    public var prompts: PromptBuilder
    /// Reads the user's mood for emotion-aware tones (`prompts.tone`).
    public var emotionDetector: (any EmotionDetecting)?
    /// Cross-chat profile + memory block from `PersonalContextBudget.render` (optional).
    public var memories: String?
    public var retriever: SnippetRetriever?
    /// Connector tools the model may call. Only offered when documents are not grounding the answer
    /// (grounded mode tells the model to use ONLY the passages, which conflicts with tool use) and
    /// the engine is a `ToolCallingEngine`.
    public var tools: [ToolSpec]
    /// Asked before any tool with side effects runs. Without one such tools are always declined.
    public var approver: ToolApprover?
    public var clock: @Sendable () -> Date
    /// Window tokens held back for tool results when tools are active.
    public var toolReserveTokens: Int
    public var maxToolOutputTokens: Int
    public var maxToolCalls: Int
    /// Escalating budget pressure applied on each overflow retry.
    public var retryPressures: [Double]
    public var maxSummaryTokens: Int
    /// Local intent classifier (no model call).
    public var intentRouter: IntentRouter
    /// Optional style card for on-device “write like me” rewrites.
    public var styleCard: StyleCard?

    public init(
        engine: any LLMEngine,
        context: ContextManager = ContextManager(),
        prompts: PromptBuilder = PromptBuilder(),
        emotionDetector: (any EmotionDetecting)? = LexiconEmotionDetector(),
        memories: String? = nil,
        retriever: SnippetRetriever? = nil,
        tools: [ToolSpec] = [],
        approver: ToolApprover? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        toolReserveTokens: Int = 1200,
        maxToolOutputTokens: Int = 500,
        maxToolCalls: Int = 6,
        retryPressures: [Double] = [1.0, 1.6, 2.5],
        maxSummaryTokens: Int = 220,
        intentRouter: IntentRouter = IntentRouter(),
        styleCard: StyleCard? = nil
    ) {
        self.engine = engine
        self.context = context
        self.prompts = prompts
        self.emotionDetector = emotionDetector
        self.memories = memories
        self.retriever = retriever
        self.tools = tools
        self.approver = approver
        self.clock = clock
        self.toolReserveTokens = toolReserveTokens
        self.maxToolOutputTokens = maxToolOutputTokens
        self.maxToolCalls = maxToolCalls
        self.retryPressures = retryPressures.isEmpty ? [1.0] : retryPressures
        self.maxSummaryTokens = maxSummaryTokens
        self.intentRouter = intentRouter
        self.styleCard = styleCard
    }

    public func send(
        question: String,
        state: ChatState,
        useDocuments: Bool
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await run(question: question, state: state, useDocuments: useDocuments) {
                        continuation.yield($0)
                    }
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Implementation

    private func run(
        question: String,
        state: ChatState,
        useDocuments: Bool,
        emit: @escaping @Sendable (ChatEvent) -> Void
    ) async throws -> ChatResult {
        var summary = state.summary
        var history = state.history
        var compactions = 0

        // Emotion + companion cues (optional): distress or "how are you?" get a conversation,
        // not a document lookup.
        let emotionAware = prompts.tone.isEmotionAware
        let emotion = emotionAware ? emotionDetector?.read(question) : nil
        let cue = emotionAware ? CompanionCue.detect(in: question) : .none

        let intent = intentRouter.route(
            question: question, useDocuments: useDocuments, emotion: emotion, cue: cue
        )

        // Fast path: style-card rewrite skips RAG, tools and history compaction.
        if intent == .rewrite, let card = styleCard, card.isReady {
            return try await runRewrite(
                question: question, state: state, emotion: emotion, cue: cue, emit: emit
            )
        }

        let skipDocuments = !intent.wantsDocuments
            || emotion?.needsSupport == true
            || cue == .askingAboutBot

        // Retrieval (optional).
        var candidates: [ContextSnippet] = []
        var searchQuery: String?
        let grounded = useDocuments && retriever != nil && !skipDocuments
        if grounded, let retriever {
            searchQuery = await standaloneQuery(question: question, history: history)
            candidates = try await retriever(searchQuery ?? question)
            emit(.retrieved(candidates))
        }

        // Tools: when not grounded in documents, intent allows them, and the engine supports them.
        // Casual chat still gets tools (classification cannot cover every "add lunch tomorrow").
        let toolEngine = engine as? any ToolCallingEngine
        let useTools = !grounded && intent.wantsTools && !tools.isEmpty && toolEngine != nil
        let toolNote = useTools ? PromptBuilder.toolInstructions(now: clock()) : nil
        let instructionMode = InstructionMode.resolve(intent: intent, grounded: grounded, useTools: useTools)
        let temperature = prompts.tone.samplingTemperature(grounded: grounded, intent: intent)
        let maxTokens = prompts.tone.maximumResponseTokens(grounded: grounded, intent: intent)
        var window = context
        if useTools { window.answerReserve += toolReserveTokens }

        func instructionsText(summary: String?, extra: String? = nil) -> String {
            prompts.instructions(
                summary: summary, grounded: grounded, toolNote: toolNote,
                emotion: emotion, cue: cue, memories: memories,
                mode: instructionMode, extra: extra
            )
        }

        // Proactive compaction: do not wait for an overflow error.
        if window.shouldCompact(history: history) {
            let fit = window.fit(
                instructions: instructionsText(summary: summary),
                history: history, snippets: [], question: question
            )
            if !fit.dropped.isEmpty {
                summary = await compact(summary: summary, dropped: fit.dropped)
                history = fit.history
                compactions += 1
            }
        }

        var lastError: Error = LLMEngineError.contextOverflow
        var groundingRetried = false
        for pressure in retryPressures {
            let fit = window.fit(
                instructions: instructionsText(summary: summary),
                history: history,
                snippets: candidates, question: question, pressure: pressure
            )
            if !fit.dropped.isEmpty {
                summary = await compact(summary: summary, dropped: fit.dropped)
                history = fit.history
                compactions += 1
            }

            let promptText = prompts.prompt(history: history, snippets: fit.snippets, question: question)

            do {
                let answer = try await streamAnswer(
                    instructions: instructionsText(summary: summary),
                    prompt: promptText,
                    temperature: temperature,
                    maximumResponseTokens: maxTokens,
                    useTools: useTools,
                    toolEngine: toolEngine,
                    emit: emit
                )

                // One-shot grounding verify: missing citations → reinforce and regenerate once.
                if grounded,
                   !groundingRetried,
                   PromptBuilder.needsGroundingRetry(answer: answer, snippetCount: fit.snippets.count) {
                    groundingRetried = true
                    let corrected = try await streamAnswer(
                        instructions: instructionsText(summary: summary, extra: PromptBuilder.groundingRetryNote),
                        prompt: promptText,
                        temperature: temperature,
                        maximumResponseTokens: maxTokens,
                        useTools: false,
                        toolEngine: nil,
                        emit: emit
                    )
                    return makeResult(
                        answer: corrected, question: question, snippets: fit.snippets, grounded: grounded,
                        searchQuery: searchQuery, summary: summary, history: history, compactions: compactions,
                        emotion: emotion, cue: cue, intent: intent
                    )
                }

                return makeResult(
                    answer: answer, question: question, snippets: fit.snippets, grounded: grounded,
                    searchQuery: searchQuery, summary: summary, history: history, compactions: compactions,
                    emotion: emotion, cue: cue, intent: intent
                )
            } catch LLMEngineError.contextOverflow {
                lastError = LLMEngineError.contextOverflow
                continue // retry with more pressure
            }
        }
        throw lastError
    }

    private func streamAnswer(
        instructions: String,
        prompt: String,
        temperature: Double?,
        maximumResponseTokens: Int?,
        useTools: Bool,
        toolEngine: (any ToolCallingEngine)?,
        emit: @escaping @Sendable (ChatEvent) -> Void
    ) async throws -> String {
        let request = LLMRequest(
            instructions: instructions,
            prompt: prompt,
            temperature: temperature,
            maximumResponseTokens: maximumResponseTokens
        )
        let stream: AsyncThrowingStream<String, Error>
        if useTools, let toolEngine {
            let toolGuard = ToolGuard(
                approver: approver, maxCalls: maxToolCalls, maxOutputTokens: maxToolOutputTokens,
                emit: { emit(.toolActivity($0)) }
            )
            stream = toolEngine.stream(request, tools: toolGuard.wrap(tools))
        } else {
            stream = engine.stream(request)
        }
        var answer = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            answer = snapshot
            emit(.partial(snapshot))
        }
        return answer
    }

    /// Style-card rewrite: single short generation, no retrieval or tools.
    private func runRewrite(
        question: String,
        state: ChatState,
        emotion: EmotionReading?,
        cue: CompanionCue,
        emit: @escaping @Sendable (ChatEvent) -> Void
    ) async throws -> ChatResult {
        let card = styleCard ?? StyleCard(traits: "Clear and natural", isEnabled: true)
        var request = card.rewriteRequest(draft: question)
        if request.maximumResponseTokens == nil {
            request.maximumResponseTokens = prompts.tone.maximumResponseTokens(grounded: false, intent: .rewrite)
        }
        if request.temperature == nil {
            request.temperature = prompts.tone.samplingTemperature(grounded: false, intent: .rewrite)
        }
        var answer = ""
        for try await snapshot in engine.stream(request) {
            try Task.checkCancellation()
            answer = snapshot
            emit(.partial(snapshot))
        }
        return makeResult(
            answer: answer, question: question, snippets: [], grounded: false,
            searchQuery: nil, summary: state.summary, history: state.history, compactions: 0,
            emotion: emotion, cue: cue, intent: .rewrite
        )
    }

    private func makeResult(
        answer: String, question: String, snippets: [ContextSnippet], grounded: Bool,
        searchQuery: String?, summary: String?, history: [Turn], compactions: Int,
        emotion: EmotionReading?, cue: CompanionCue, intent: ChatIntent
    ) -> ChatResult {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let cited = PromptBuilder.citations(in: trimmed).filter { $0 >= 1 && $0 <= snippets.count }
        var newHistory = history
        newHistory.append(Turn(role: .user, text: question))
        newHistory.append(Turn(role: .assistant, text: trimmed))
        return ChatResult(
            answer: trimmed,
            snippets: snippets,
            citedIndices: cited,
            notFound: grounded && trimmed.contains(PromptBuilder.notFoundPhrase),
            searchQuery: searchQuery,
            state: ChatState(summary: summary, history: newHistory),
            compactions: compactions,
            emotion: emotion,
            cue: cue,
            intent: intent
        )
    }

    /// Rewrite a follow-up into a standalone query; falls back to the raw question.
    private func standaloneQuery(question: String, history: [Turn]) async -> String {
        guard !history.isEmpty else { return question }
        let request = prompts.rewriteRequest(history: history, question: question)
        guard let rewritten = try? await engine.respond(request) else { return question }
        let cleaned = rewritten
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !cleaned.isEmpty, cleaned.count < 300 else { return question }
        return cleaned
    }

    /// Fold dropped turns into the rolling summary. Falls back to a mechanical summary if
    /// the model call fails, so a compaction never blocks the user's question.
    private func compact(summary: String?, dropped: [Turn]) async -> String? {
        let request = prompts.summaryRequest(existingSummary: summary, dropped: dropped)
        let updated: String
        if let generated = try? await engine.respond(request),
           !generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let mechanical = dropped.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }.joined(separator: " ")
            updated = [summary, mechanical].compactMap { $0 }.joined(separator: " ")
        }
        return TokenEstimator.truncate(updated, toTokens: maxSummaryTokens)
    }
}
