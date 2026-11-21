import Foundation
import Observation
import LLMKit

/// Bridges the model's tool calls to the UI: when a tool wants to change something (save a Gmail
/// draft, add a calendar event), the chat pauses here until the user taps Approve or Decline.
///
/// Anything other than an explicit approval counts as a decline: dismissing the sheet, leaving the
/// chat, stopping the answer, or a second request arriving.
@MainActor
@Observable
final class ApprovalCoordinator {
    private(set) var pending: ApprovalRequest?

    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    /// Shows `request` and suspends until the user decides.
    func request(_ request: ApprovalRequest) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Only one approval can be on screen. A new one declines whatever was waiting.
                self.continuation?.resume(returning: false)
                self.continuation = continuation
                self.pending = request
                if Task.isCancelled { self.resolve(false, requestID: request.id) }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(false, requestID: request.id) }
        }
    }

    /// Completes the pending approval. `requestID` guards against a late cancel resolving a newer request.
    func resolve(_ approved: Bool, requestID: UUID? = nil) {
        guard let pending, requestID == nil || pending.id == requestID else { return }
        self.pending = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: approved)
    }
}
