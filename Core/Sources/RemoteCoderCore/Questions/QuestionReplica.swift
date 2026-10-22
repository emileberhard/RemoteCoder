import Foundation
import Observation

@MainActor @Observable
final class QuestionReplica {
    private static let editorLimit = 32

    private(set) var pendingAskTimesByThreadID: [String: [Int64]] = [:]
    @ObservationIgnored private let hostID: UUID
    @ObservationIgnored private let remote: any QuestionRemote
    @ObservationIgnored private let sessions: ConversationSessions
    @ObservationIgnored private let presentedPrompt: @MainActor (QuestionAddress) -> QuestionPrompt?
    @ObservationIgnored private var scopes: Set<String> = []
    @ObservationIgnored private var reader: QuestionReadCoordinator?
    @ObservationIgnored private var editors: [QuestionAddress: QuestionEditor] = [:]
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private let commands = OwnedTasks<Bool>()

    init(hostID: UUID, remote: any QuestionRemote, sessions: ConversationSessions,
         presentedPrompt: @escaping @MainActor (QuestionAddress) -> QuestionPrompt?) {
        self.hostID = hostID
        self.remote = remote
        self.sessions = sessions
        self.presentedPrompt = presentedPrompt
    }

    func record(_ snapshot: ConversationSnapshot) {
        guard let threadID = snapshot.threadID else { return }
        let askTimes = snapshot.questionCoverage == .ready
            ? snapshot.questionPrompts.values.filter(\.isPending).compactMap(\.record?.askedAtMs).sorted()
            : nil
        record(threadID: threadID, askTimes: askTimes)
    }

    private func record(threadID: String, askTimes: [Int64]?) {
        if pendingAskTimesByThreadID[threadID] != askTimes { pendingAskTimesByThreadID[threadID] = askTimes }
    }

    func requestScopes(_ scopes: Set<String>) {
        adopt(scopes)
        for thread in scopes { questionReader().request(threadID: thread) }
    }

    func requestAddedScopes(_ scopes: Set<String>) {
        let previous = self.scopes
        adopt(scopes)
        for thread in scopes.subtracting(previous) { questionReader().request(threadID: thread) }
    }

    func sessionBound(_ snapshot: ConversationSnapshot) {
        guard !isStopped, let threadID = snapshot.threadID, scopes.contains(threadID),
              snapshot.questionCoverage != .ready else { return }
        questionReader().request(threadID: threadID)
    }

    func changed(_ change: ServerNotification.QuestionsChanged) {
        questionReader().changed(threadID: change.threadID, epoch: change.epoch, revision: change.revision, itemIDs: change.itemIDs)
    }

    func invalidate() async {
        await reader?.invalidate()
    }

    func forgetCounts() {
        pendingAskTimesByThreadID.removeAll()
    }

    func refresh(_ address: QuestionAddress) async {
        guard !isStopped, address.conversation.hostID == hostID else { return }
        await questionReader().refresh(threadID: address.conversation.threadID, itemIDs: [address.itemID])
    }

    func editor(for address: QuestionAddress, prompt: QuestionPrompt, activeThreadID: String?,
                submit: @escaping (QuestionAddress, [QuestionReplyEnvelope.Entry], QuestionVersion) async throws -> UUID) -> QuestionEditor {
        if let existing = editors[address], existing.epoch == prompt.epoch { return existing }
        editors.removeValue(forKey: address)?.stop()
        if editors.count >= Self.editorLimit {
            let removable = editors.first { $0.key.conversation.threadID != activeThreadID }?.key
            if let removable { editors.removeValue(forKey: removable)?.stop() }
        }
        let editor = QuestionEditor(prompt: prompt,
            submit: { [commands] entries, version in
                try await commands.perform { try await submit(address, entries, version) }
            },
            dismiss: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.commands.perform { try await self.dismiss(address) }
            }, refresh: { [weak self] in await self?.refresh(address) },
            allowResend: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.commands.perform { try await self.authorizeResend(address, receiptID: id) }
            })
        editors[address] = editor
        return editor
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        isStopped = true
        commands.quiesce()
        editors.values.forEach { $0.stop() }
        return reader?.stop()
    }

    func quiesce() -> [Task<Void, Never>] {
        isStopped = true
        commands.quiesce()
        return editors.values.compactMap { $0.stop() } + [reader?.stop()].compactMap { $0 }
    }

    func drain() async { await commands.drain() }

    func resume() {
        commands.resume()
        isStopped = false
        editors.values.forEach { $0.resume() }
        reader?.resume()
        requestScopes(scopes)
    }

    private func questionReader() -> QuestionReadCoordinator {
        if let reader { return reader }
        let reader = QuestionReadCoordinator(remote: remote, sessions: sessions) { [weak self] threadID, askTimes in
            guard let self, !self.isStopped, self.scopes.contains(threadID) else { return }
            self.record(threadID: threadID, askTimes: askTimes)
        }
        self.reader = reader
        return reader
    }

    private func adopt(_ scopes: Set<String>) {
        self.scopes = scopes
        let retained = pendingAskTimesByThreadID.filter { scopes.contains($0.key) }
        if retained != pendingAskTimesByThreadID { pendingAskTimesByThreadID = retained }
    }

    private func dismiss(_ address: QuestionAddress) async throws {
        guard let prompt = presentedPrompt(address), let record = prompt.record, let version = prompt.version, prompt.isCurrent else {
            throw ConversationState.QuestionSubmissionError.stale
        }
        let session = await sessions.session(threadID: address.conversation.threadID)
        let request = try await session.prepareQuestionDismissal(itemID: record.itemId, version: version)
        let response = try await remote.dismissQuestion(request)
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
        try await session.finishQuestionDismissal(itemID: record.itemId)
        await refresh(address)
        if response.status == .conflict { throw ConversationState.QuestionSubmissionError.stale }
    }

    private func authorizeResend(_ address: QuestionAddress, receiptID: UUID) async throws {
        guard address.conversation.hostID == hostID, !isStopped else { throw CancellationError() }
        await refresh(address)
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
        let session = await sessions.session(threadID: address.conversation.threadID)
        try Task.checkCancellation()
        try await session.authorizeQuestionResend(receiptID)
    }
}
