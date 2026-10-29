import Foundation
import Testing
@testable import RemoteCoderCore

struct CheckpointAdoptionTests: ConversationHistoryFixtures {
    @Test func damagedAdoptedCheckpointUsesTheExistingRecoveryPath() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), id = UUID()
        var source = ConversationState(conversationID: id, threadID: "thread")
        source.submit(ChatMessage(role: .user, text: "Preserve damaged adopted input"))
        let store = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await store.adopt(.invalidated(source.checkpoint), conversationID: id, threadID: "thread", importID: UUID())
        let directory = temporary.storage.root.appending(path: "conversations-v1/\(host)")
        let database = try CheckpointDatabase(url: directory.appending(path: "\(id).sqlite"), access: .persistence)
        let records = try database.read()
        let damaged = Data("Unreadable adopted header".utf8)
        _ = try database.replace(records.map { $0.key == "header" ? .init(key: $0.key, data: damaged) : $0 },
            retaining: Set(records.map(\.key)))
        let cold = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        #expect(try await cold.restore(id, threadID: "thread", generation: nil).requiresAuthoritativeHistory)
        let files = try #require(FileManager.default.enumerator(at: directory.appending(path: "recovery/\(id)"),
            includingPropertiesForKeys: nil)?.allObjects as? [URL])
        let recovered = try #require(files.first { $0.pathExtension == "sqlite" })
        #expect(try CheckpointDatabase(url: recovered, access: .inspection).readHeader() == damaged)
        #expect(await cold.accountedDiskBytes >= damaged.count)
    }

    @Test(arguments: [false, true], [false, true])
    func canonicalEchoRetainsImportedPresentationWithoutDuplicatingThePrompt(settled: Bool, sameItemID: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), id = UUID()
        let image = CodexImageAttachment(id: UUID(), data: Data(repeating: 42, count: 64), format: .jpeg,
            pixelSize: .init(width: 1, height: 1))
        let inline = InlineMessageContent(.init(runs: [.text("Keep inline presentation")]))
        let message = ChatMessage(role: .user, text: "Canonical input", attachments: [.init(id: image.id, content: .imageData(image))], inlineContent: inline)
        let itemID = sameItemID ? message.id.uuidString : "echo"
        let snapshot = history(items: [.userMessage(id: itemID, content: [.text(text: message.text, textElements: []),
            .image(.inline(url: "data:image/jpeg;base64," + image.data.base64EncodedString()))], clientId: message.id.uuidString.lowercased())])
        var canonical = ConversationState(conversationID: id, threadID: "thread")
        canonical.merge(snapshot)
        let store = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await store.save(canonical.checkpoint, conversationID: id)
        var source = ConversationState(conversationID: id, threadID: "thread")
        source.submit(message)
        if settled { source.merge(snapshot) }
        try await store.adopt(.invalidated(source.checkpoint), conversationID: id, threadID: "thread", importID: UUID())
        let restored = try #require(try await store.restore(id, threadID: "thread", generation: nil).checkpoint)
        #expect(restored.submissions.isEmpty)
        #expect(restored.turns.values.reduce(0) { $0 + $1.items.count } == 1)
        let local = try #require(restored.turns["turn"]?.items[itemID]?.localMessage)
        var visible = ConversationState(conversationID: id, threadID: "thread")
        visible.restore(restored)
        #expect(ConversationProjection.project(visible).messages.map(\.id) == [message.id])
        #expect(local.inlineContent == inline)
        #expect(local.attachments.first?.id == image.id)
        guard case .canonicalImage(let index) = try #require(local.attachments.first).content else {
            Issue.record("The matching canonical image must replace duplicated bytes")
            return
        }
        #expect(index == 0)
    }

    @Test(arguments: [false, true])
    func invalidatedAdoptionKeepsUniqueLocalsDismissalsAndPendingSubmissions(aboveCapacity: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID(), id = UUID()
        let limit = aboveCapacity ? 1 : 512 * 1_024 * 1_024
        let store = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: limit)
        var original = ConversationState(conversationID: id, threadID: "thread")
        let pending = ChatMessage(role: .user, text: "Pending source input")
        original.submit(pending)
        original.appendLocal(ChatMessage(role: .codex, text: "Unique source answer"), turnID: "source")
        original.questionDismissals = ["source": .init(threadId: "thread", itemId: "source", expectedRecordRevision: 1,
            expectedEpoch: "epoch", mutationId: UUID())]
        let firstImport = UUID()
        try await store.adopt(.invalidated(original.checkpoint), conversationID: id, threadID: "thread", importID: firstImport)
        var other = ConversationState(conversationID: id, threadID: "thread")
        other.appendLocal(ChatMessage(role: .codex, text: "Later local answer"), turnID: "source")
        other.turns["source"]?.terminal = true
        other.questionDismissals = ["other": .init(threadId: "thread", itemId: "other", expectedRecordRevision: 2,
            expectedEpoch: "epoch", mutationId: UUID())]
        let secondImport = UUID()
        try await store.adopt(.checkpoint(other.checkpoint), conversationID: id, threadID: "thread", importID: secondImport)
        try await store.adopt(.invalidated(original.checkpoint), conversationID: id, threadID: "thread", importID: firstImport)
        let cold = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: limit)
        let result = try await cold.restore(id, threadID: "thread", generation: nil)
        #expect(result.requiresAuthoritativeHistory)
        let checkpoint = try #require(result.checkpoint)
        #expect(checkpoint.submissions[pending.id]?.message.text == pending.text)
        #expect(checkpoint.turns["source"]?.items.values.contains { $0.localMessage?.text == "Unique source answer" } == true)
        #expect(Set(checkpoint.questionDismissals?.keys ?? [:].keys) == ["source", "other"])
        #expect(checkpoint.accountImports == [firstImport, secondImport])
        try await cold.save(original.checkpoint, conversationID: id)
        let protected = try #require(try await cold.restore(id, threadID: "thread", generation: nil).checkpoint)
        #expect(protected.accountImports == [firstImport, secondImport])
        #expect(protected.turns["source"]?.items.values.contains { $0.localMessage?.text == "Later local answer" } == true)
        let inventory = try #require(await cold.inventory(threadIDs: [:]))
        #expect(inventory.entries.first?.invalidation == "history")
        #expect(inventory.totals.primaryPayloadBytes > 1)
        let generation = await cold.generation(for: id)
        let newer = ChatMessage(role: .user, text: "New input still uses normal admission")
        other.submit(newer)
        let record = ConversationCheckpointStore.SubmissionRecord(revision: other.persistenceRevision, threadID: "thread",
            submission: try #require(other.submissions[newer.id]))
        if aboveCapacity {
            await #expect(throws: ConversationCheckpointStore.CapacityOverflow.self) {
                try await cold.saveSubmission(record, conversationID: id, generation: generation)
            }
        } else {
            try await cold.saveSubmission(record, conversationID: id, generation: generation)
            let updated = ConversationCheckpointStore(hostID: host, storage: temporary.storage, primaryBudgetBytes: limit)
            let restored = try await updated.restore(id, threadID: "thread", generation: nil)
            #expect(restored.requiresAuthoritativeHistory)
            #expect(restored.checkpoint?.submissions[newer.id]?.message.text == newer.text)
        }
    }
}
