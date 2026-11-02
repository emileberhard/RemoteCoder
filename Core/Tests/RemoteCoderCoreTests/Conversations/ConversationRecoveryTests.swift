import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationRecoveryTests {
    @Test func anUnreadableCheckpointIsPreservedWhileSubmissionAndFlushProceed() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let url = directory.appending(path: "\(id).json")
        let original = Data("unreadable checkpoint with local records".utf8)
        try original.write(to: url)
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
        let message = ChatMessage(role: .user, text: "Recovered durable input")
        _ = try await session.submitDurably(message)
        _ = try await session.submit(ChatMessage(role: .user, text: "Late event"))
        try await session.flush()
        #expect(await session.beginHistoryRead().base == nil)
        let incidents = try FileManager.default.contentsOfDirectory(at: directory.appending(path: "recovery/\(id)"), includingPropertiesForKeys: nil)
        #expect(incidents.count == 1)
        #expect(try Data(contentsOf: incidents[0].appending(path: "\(id).json")) == original)
        let cold = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let saved = try #require(try await cold.load(id))
        #expect(saved.submissions[message.id]?.message.text == message.text)
        #expect(saved.containsLocalRecords)
        #expect(try Data(contentsOf: incidents[0].appending(path: "\(id).json")) == original)
    }

    @Test func flushRestoresExistingLocalRecordsBeforeSavingLiveChanges() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let id = UUID()
        var old = ConversationState(conversationID: id)
        old.submit(ChatMessage(role: .user, text: "Unacknowledged local message"))
        try await store.save(old.checkpoint, conversationID: id)
        let session = await ConversationSession.make(conversationID: id, checkpoints: store)
        _ = try await session.submit(ChatMessage(role: .user, text: "New event before restore"))
        try await session.flush()
        let saved = try #require(try await store.load(id))
        #expect(saved.submissions.count == 2)
        #expect(await session.snapshot().messages.count == 2)
    }

    @Test func aRemovedMessageThatWasNotSentStaysRemovedAfterReopening() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let id = UUID()
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
        let message = ChatMessage(role: .user, text: "Refused")
        _ = try await session.submitDurably(message)
        await session.submissionFailed(message.id, failure: .rejected("Open in another client"))
        let failed = try #require(await session.snapshot().messages.first { $0.id == message.id })
        #expect(failed.delivery == .notSent)
        #expect(failed.deliveryError == "Open in another client")

        await session.removeNotSent(message.id)
        try await session.flush()
        #expect(await session.snapshot().messages.isEmpty)

        let cold = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let reopened = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: cold)
        try await reopened.restore()
        #expect(await reopened.snapshot().messages.isEmpty)
    }

    @Test func restoringDropsRetiredLocalErrorNotices() {
        var saved = ConversationState(conversationID: UUID(), threadID: "thread")
        let kept = ChatMessage(role: .user, text: "Kept")
        saved.submit(kept)
        let checkpoint = saved.checkpoint
        let notice = ChatMessage(role: .codex, text: "Gateway error")
        let noticeTurn = ConversationState.Turn(id: ConversationState.localTurnID(notice.id), order: [notice.id.uuidString],
            items: [notice.id.uuidString: .init(value: .agentMessage(id: notice.id.uuidString, text: notice.text),
                completed: true, detailed: true, isLocal: true, localMessage: notice)])
        var turns = checkpoint.turns
        turns[noticeTurn.id] = noticeTurn
        let legacy = ConversationState.Checkpoint(revision: checkpoint.revision, threadID: checkpoint.threadID,
            order: checkpoint.order + [noticeTurn.id], turns: turns, submissions: checkpoint.submissions, historyWindow: nil)

        var restored = ConversationState(conversationID: saved.conversationID, threadID: "thread")
        restored.restore(legacy)

        #expect(restored.order == [ConversationState.localTurnID(kept.id)])
        #expect(ConversationProjection.project(restored).messages.map(\.text) == ["Kept"])
    }
}
