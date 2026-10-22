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
        await session.appendLocal(ChatMessage(role: .codex, text: "Late event"))
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
        await session.appendLocal(ChatMessage(role: .codex, text: "New event before restore"))
        try await session.flush()
        let saved = try #require(try await store.load(id))
        #expect(saved.submissions.count == 1)
        #expect(await session.snapshot().messages.count == 2)
    }
}
