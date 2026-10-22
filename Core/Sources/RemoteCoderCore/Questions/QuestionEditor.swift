import Foundation
import Observation

/// Editing and command lifetime for one host/thread/question. The host record
/// and the conversation's submission receipt, not this editor, decide resolution.
@Observable @MainActor
final class QuestionEditor {
    let epoch: String?
    var flow: QuestionFlow
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var submissionID: UUID?
    private(set) var answeringAnyway = false
    @ObservationIgnored private var acceptsWork = true
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let submit: ([QuestionReplyEnvelope.Entry], QuestionVersion) async throws -> UUID
    @ObservationIgnored private let dismiss: () async throws -> Void
    @ObservationIgnored private let refresh: () async -> Void
    @ObservationIgnored private let allowResend: (UUID) async throws -> Void

    init(prompt: QuestionPrompt,
         submit: @escaping ([QuestionReplyEnvelope.Entry], QuestionVersion) async throws -> UUID,
         dismiss: @escaping () async throws -> Void,
         refresh: @escaping () async -> Void,
         allowResend: @escaping (UUID) async throws -> Void) {
        flow = QuestionFlow(questions: prompt.questions)
        epoch = prompt.epoch
        self.submit = submit
        self.dismiss = dismiss
        self.refresh = refresh
        self.allowResend = allowResend
        reconcile(prompt)
    }

    func reconcile(_ prompt: QuestionPrompt) {
        guard prompt.epoch == epoch else { flow.updateIndices([]); return }
        let indices = answeringAnyway ? (prompt.record?.questions.filter {
            $0.resolution == .dismissed || $0.resolution == .superseded
        }.map(\.index) ?? []) : prompt.pendingIndices
        flow.updateIndices(indices.filter { index in
            !prompt.deliveries.contains { $0.preventsSend && $0.indices.contains(index) }
        })
    }

    func answerAnyway(_ prompt: QuestionPrompt) {
        answeringAnyway = true
        reconcile(prompt)
    }

    func wasAdmitted(in prompt: QuestionPrompt) -> Bool {
        guard let submissionID else { return false }
        return prompt.deliveries.contains { $0.id == submissionID && ($0.status == .accepted || $0.status == .confirmed) }
            || prompt.record?.questions.contains { $0.answer?.clientId.flatMap(UUID.init(uuidString:)) == submissionID } == true
    }

    func send(_ prompt: QuestionPrompt) {
        guard !isBusy, prompt.isCurrent, prompt.epoch == epoch, let version = prompt.version else { return }
        reconcile(prompt)
        guard let entries = flow.entries(itemID: prompt.itemID) else { return }
        perform { self.submissionID = try await self.submit(entries, version) }
    }

    func dismissQuestion() { perform { try await self.dismiss() } }
    func checkStatus() { perform { await self.refresh() } }
    func authorizeResend(_ id: UUID) { perform { try await self.allowResend(id); self.submissionID = nil } }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        acceptsWork = false
        let running = task
        running?.cancel()
        task = nil
        isBusy = false
        return running
    }

    func resume() { acceptsWork = true }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard acceptsWork, !isBusy else { return }
        isBusy = true
        error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.task = nil }
            do { try await operation() }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
}
