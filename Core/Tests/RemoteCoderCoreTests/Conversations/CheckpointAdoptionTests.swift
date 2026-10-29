import Foundation
import Testing
@testable import RemoteCoderCore

struct CheckpointAdoptionTests {
    @Test func invalidatedAdoptionKeepsUniqueLocalsDismissalsAndPendingSubmissionsAboveCapacity() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), id = UUID()
        let store = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 1)
        var original = ConversationState(conversationID: id, threadID: "thread")
        let pending = ChatMessage(role: .user, text: "Pending source input")
        original.submit(pending)
        original.appendLocal(ChatMessage(role: .codex, text: "Unique source answer"), turnID: "source")
        original.questionDismissals = ["source": .init(threadId: "thread", itemId: "source", expectedRecordRevision: 1,
            expectedEpoch: "epoch", mutationId: UUID())]
        let firstImport = UUID()
        try await store.adopt(.invalidated(original.checkpoint), conversationID: id, threadID: "thread", importID: firstImport)
        var other = ConversationState(conversationID: id, threadID: "thread")
        other.questionDismissals = ["other": .init(threadId: "thread", itemId: "other", expectedRecordRevision: 2,
            expectedEpoch: "epoch", mutationId: UUID())]
        let secondImport = UUID()
        try await store.adopt(.checkpoint(other.checkpoint), conversationID: id, threadID: "thread", importID: secondImport)
        try await store.adopt(.invalidated(original.checkpoint), conversationID: id, threadID: "thread", importID: firstImport)
        let cold = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 1)
        let result = try await cold.restore(id, threadID: "thread", generation: nil)
        #expect(result.requiresAuthoritativeHistory)
        let checkpoint = try #require(result.checkpoint)
        #expect(checkpoint.submissions[pending.id]?.message.text == pending.text)
        #expect(checkpoint.turns["source"]?.items.values.contains { $0.localMessage?.text == "Unique source answer" } == true)
        #expect(Set(checkpoint.questionDismissals?.keys ?? [:].keys) == ["source", "other"])
        #expect(checkpoint.accountImports == [firstImport, secondImport])
        let inventory = try #require(await cold.inventory(threadIDs: [:]))
        #expect(inventory.entries.first?.invalidation == "history")
        #expect(inventory.totals.primaryPayloadBytes > 1)
        let generation = await cold.generation(for: id)
        let newer = ChatMessage(role: .user, text: "New input still uses normal admission")
        other.submit(newer)
        await #expect(throws: ConversationCheckpointStore.CapacityOverflow.self) {
            try await cold.saveSubmission(.init(revision: other.persistenceRevision, threadID: "thread",
                submission: try #require(other.submissions[newer.id])), conversationID: id, generation: generation)
        }
    }
}
