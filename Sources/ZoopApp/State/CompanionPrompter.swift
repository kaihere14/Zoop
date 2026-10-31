import Foundation
import ZoopAgents
import ZoopShared

/// One in-app question at a time for the single executing task. Cancellation unblocks the
/// model instead of leaving a continuation waiting after shutdown.
actor CompanionPrompter: UserPrompting {
    struct Question: Identifiable, Sendable {
        let id: UUID
        let text: String
        var kind: QuestionKind = .info
        var permission: PermissionPrompt?
    }
    private var waiting: (UUID, CheckedContinuation<String?, Never>)?
    private let onQuestion: @Sendable (Question?) -> Void

    init(onQuestion: @escaping @Sendable (Question?) -> Void) { self.onQuestion = onQuestion }

    func ask(_ question: String) async -> String? { await ask(question, kind: .info) }

    func ask(_ question: String, kind: QuestionKind) async -> String? {
        await present(Question(id: UUID(), text: question, kind: kind))
    }

    func choosePermission(_ prompt: PermissionPrompt) async -> String? {
        await present(Question(id: UUID(), text: prompt.message, permission: prompt))
    }

    private func present(_ question: Question) async -> String? {
        let id = question.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                guard waiting == nil else { continuation.resume(returning: nil); return }
                waiting = (id, continuation)
                onQuestion(question)
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func answer(_ id: UUID, text: String) {
        guard let (current, continuation) = waiting, current == id else { return }
        waiting = nil; onQuestion(nil)
        continuation.resume(returning: text)
    }

    private func cancel(_ id: UUID) {
        guard let (current, continuation) = waiting, current == id else { return }
        waiting = nil; onQuestion(nil)
        continuation.resume(returning: nil)
    }
}
