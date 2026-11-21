import Foundation
import Observation
import SwiftData
import LLMKit
import RAGKit

/// Drives one chat screen: sends questions through `ChatPipeline` and persists the results.
@MainActor
@Observable
final class ChatController {
    private(set) var isResponding = false
    private(set) var status: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var failedQuestion: String?
    @ObservationIgnored private var failedUserMessage: ChatMessage?

    func send(_ text: String, conversation: Conversation, environment: AppEnvironment, context: ModelContext) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        errorMessage = nil
        failedQuestion = nil

        // History = valid messages that have not yet been folded into the rolling summary.
        let pending = Array(conversation.validMessages.dropFirst(conversation.summarizedCount))
        let history = pending.map { Turn(role: $0.role, text: $0.text) }

        let userMessage = ChatMessage(role: .user, text: question)
        context.insert(userMessage)
        userMessage.conversation = conversation
        conversation.updatedAt = Date()

        // Forget attached documents that were deleted from the library since the last message.
        let existing = Set(environment.documents.map(\.id))
        conversation.scopeIDs = DocumentScope.pruned(conversation.scopeIDs, existing: existing)
        let useDocuments = conversation.useDocuments && !environment.documents.isEmpty
        let scope = DocumentScope.searchScope(conversation.scopeIDs, existing: existing)
        let tone = environment.chatTone
        let basePipeline = ChatPipeline(
            engine: environment.engine,
            prompts: PromptBuilder(tone: tone),
            emotionDetector: Self.emotionDetector,
            retriever: environment.knowledgeBase.retriever(limit: environment.retrievalLimit, scope: scope)
        )
        let state = ChatState(summary: conversation.summary, history: history)
        let connectors = environment.connectors
        let approvals = environment.approvals

        isResponding = true
        status = useDocuments ? "Searching your documents…" : nil

        task = Task { [weak self] in
            var assistant: ChatMessage?
            var usedTools: [String] = []
            // Connector tools (Gmail, Calendar...) for this answer. Actions that change something
            // pause here until the user approves them in the approval sheet.
            var pipeline = basePipeline
            pipeline.tools = await connectors.activeTools()
            pipeline.approver = { request in await approvals.request(request) }
            do {
                for try await event in pipeline.send(question: question, state: state, useDocuments: useDocuments) {
                    guard let self else { return }
                    switch event {
                    case .retrieved(let snippets):
                        self.status = snippets.isEmpty ? "No matching passages found" : "Reading \(snippets.count) passages…"
                    case .toolActivity(let activity):
                        switch activity.phase {
                        case .awaitingApproval: self.status = "Waiting for your approval…"
                        case .running: self.status = activity.label + "…"
                        case .finished:
                            self.status = nil
                            if !usedTools.contains(activity.label) { usedTools.append(activity.label) }
                        case .failed, .declined: self.status = nil
                        }
                    case .partial(let partial):
                        self.status = nil
                        if assistant == nil {
                            let message = ChatMessage(role: .assistant, text: partial)
                            context.insert(message)
                            message.conversation = conversation
                            assistant = message
                        } else {
                            assistant?.text = partial
                        }
                    case .finished(let result):
                        let message = assistant ?? {
                            let created = ChatMessage(role: .assistant, text: result.answer)
                            context.insert(created)
                            created.conversation = conversation
                            return created
                        }()
                        self.finalize(result, message: message, conversation: conversation,
                                      question: question, inputHistoryCount: history.count)
                        message.toolsUsed = usedTools
                    }
                }
            } catch {
                self?.fail(error, question: question, userMessage: userMessage, partial: assistant, context: context)
            }
            guard let self else { return }
            self.isResponding = false
            self.status = nil
            conversation.updatedAt = Date()
            try? context.save()
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Retry the last failed question.
    func retry(conversation: Conversation, environment: AppEnvironment, context: ModelContext) {
        guard let question = failedQuestion else { return }
        if let failedUserMessage { context.delete(failedUserMessage) }
        failedUserMessage = nil
        send(question, conversation: conversation, environment: environment, context: context)
    }

    // MARK: -

    private func finalize(
        _ result: ChatResult, message: ChatMessage, conversation: Conversation,
        question: String, inputHistoryCount: Int
    ) {
        message.text = result.answer
        message.notFound = result.notFound
        message.searchQuery = result.searchQuery
        message.sources = result.snippets.enumerated().map { offset, snippet in
            SourceRef(
                index: offset + 1, title: snippet.title, location: snippet.location, text: snippet.text,
                cited: result.citedIndices.contains(offset + 1)
            )
        }

        // result.state.history = kept turns + this exchange, so the rest were folded into the summary.
        let keptBeforeExchange = max(0, result.state.history.count - 2)
        let folded = max(0, inputHistoryCount - keptBeforeExchange)
        conversation.summarizedCount += folded
        conversation.summary = result.state.summary

        if conversation.title == "New chat" {
            conversation.title = Self.title(from: question)
        }
    }

    private func fail(
        _ error: Error, question: String, userMessage: ChatMessage, partial: ChatMessage?, context: ModelContext
    ) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let partial, !partial.text.isEmpty {
            // Keep what was generated; the exchange still counts as part of the conversation.
            return
        }
        // Nothing was produced: remove the orphan question so a retry does not duplicate it.
        failedQuestion = question
        failedUserMessage = userMessage
        userMessage.isError = true
    }

    /// Apple's sentiment model on top of the keyword detector where available.
    private static let emotionDetector: any EmotionDetecting = {
        #if canImport(NaturalLanguage)
        SentimentEmotionDetector()
        #else
        LexiconEmotionDetector()
        #endif
    }()

    static func title(from question: String) -> String {
        let cleaned = question.replacingOccurrences(of: "\n", with: " ")
        return cleaned.count > 40 ? String(cleaned.prefix(40)) + "…" : cleaned
    }
}
