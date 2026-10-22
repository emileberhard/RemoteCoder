import Foundation
import Testing
@testable import RemoteCoderCore

struct PersistenceTests {
    @Test func cleanAndColdFlushDoNotRewriteAnExistingCheckpoint() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let host = UUID()
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
        _ = try await session.submitDurably(ChatMessage(role: .user, text: "Durable before dispatch"))
        try await session.flush()
        let saved = try #require(try await store.load(id))
        #expect(saved.submissions.count == 1)
        let url = directory.appending(path: "\(id).sqlite")
        let before = try CheckpointIdentity(url)
        for _ in 0..<10 { try await session.flush() }
        let cold = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024))
        try await cold.restore()
        try await cold.flush()
        #expect(try CheckpointIdentity(url) == before)
        #expect(await cold.snapshot().messages.first?.text == "Durable before dispatch")
    }

    @Test func checkpointFailureDoesNotMarkContentClean() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.appendLocal(ChatMessage(role: .codex, text: "Only on this device"), turnID: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await #expect(throws: (any Error).self) { try await store.save(state.checkpoint, conversationID: state.conversationID) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try await store.save(state.checkpoint, conversationID: state.conversationID)
        let saved = try #require(try await store.load(state.conversationID))
        #expect(saved.durableRevision == state.persistenceRevision)
        #expect(saved.containsLocalRecords)
    }

    @Test func emptyInitialCheckpointAndConcurrentRevisionsRemainValid() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        try await store.save(state.checkpoint, conversationID: state.conversationID)
        #expect(try await store.load(state.conversationID)?.durableRevision == 0)
        var snapshots: [ConversationState.Checkpoint] = []
        for index in 0..<20 {
            state.appendLocal(ChatMessage(role: .codex, text: "Record \(index)"), turnID: nil)
            snapshots.append(state.checkpoint)
        }
        let id = state.conversationID
        try await withThrowingTaskGroup(of: Void.self) { group in
            for snapshot in snapshots.reversed() { group.addTask { try await store.save(snapshot, conversationID: id) } }
            try await group.waitForAll()
        }
        #expect(try await store.load(id)?.durableRevision == state.persistenceRevision)
    }

    @Test func questionRefreshVersionsAndConnectionStateDoNotRewriteTranscript() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let id = UUID()
        let session = await ConversationSession.make(conversationID: id, threadID: "thread", checkpoints: store)
        await session.appendLocal(ChatMessage(role: .codex,
            text: String(repeating: "Retained transcript. ", count: 20_000)))
        func inventory(_ revision: UInt64) -> QuestionHostSnapshot {
            .init(threadId: "thread", epoch: "epoch", revision: revision,
                  coverage: .ready, reason: nil, records: [], pendingItemIds: [], missingItemIds: [])
        }
        let initial = try await session.mergeQuestions(inventory(1))
        try await session.flush()
        let url = directory.appending(path: "\(id).sqlite")
        let before = try CheckpointIdentity(url)
        for revision in UInt64(2)...32 {
            let refreshed = try await session.mergeQuestions(inventory(revision))
            #expect(refreshed.revision == initial.revision)
            try await session.flush()
        }
        #expect(try CheckpointIdentity(url) == before)
        await session.invalidateQuestions("Disconnected")
        let unavailable = await session.snapshot()
        #expect(unavailable.questionCoverage == .unavailable)
        try await session.flush()
        let ready = try await session.mergeQuestions(inventory(33))
        #expect(ready.questionCoverage == .ready)
        try await session.flush()
        #expect(try CheckpointIdentity(url) == before)

        let record = QuestionRecord(itemId: "question", turnId: "turn", ordinal: 1,
            askedAtMs: nil, revision: 34, questions: [
                .init(index: 0, title: "Continue?", options: ["A"], resolution: .pending, answer: nil)
            ])
        _ = try await session.mergeQuestions(.init(threadId: "thread", epoch: "epoch", revision: 34,
            coverage: .ready, reason: nil, records: [record], pendingItemIds: ["question"], missingItemIds: []))
        try await session.flush()
        #expect(try CheckpointIdentity(url) != before)
        let saved = try #require(try await store.load(id))
        #expect(saved.questions?.records["question"] == record)
        #expect(saved.containsLocalRecords)
    }

}
