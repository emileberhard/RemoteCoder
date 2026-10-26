import Foundation
import Testing
@testable import RemoteCoderCore

struct CheckpointInventoryTests: ConversationHistoryFixtures {
    @Test(arguments: [false, true])
    func inventoryUsesLoadedBookkeepingAfterFilesBecomeUnreadable(cold: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 1_000_000)
        #expect(await store.inventory(threadIDs: [:]) == nil)
        var state = ConversationState(conversationID: UUID(), threadID: "synthetic-thread")
        state.submit(ChatMessage(role: .user, text: "Private content must never appear in telemetry"))
        try await store.save(state.checkpoint, conversationID: state.conversationID)
        let observer = cold ? ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 1_000_000) : store
        if cold { _ = try await observer.load(state.conversationID) }
        let before = try #require(await observer.inventory(threadIDs: [:]))
        let entry = try #require(before.entries.first)
        #expect(before.hostID == host)
        #expect(before.totals.records == 1)
        #expect(entry.threadID == "synthetic-thread")
        #expect(entry.contents?.turnCount == 1)
        #expect(entry.protected == true)
        #expect(entry.primaryPayloadBytes > 0)
        try FileManager.default.removeItem(at: directory)
        let after = try #require(await observer.inventory(threadIDs: [:]))
        #expect(after.totals.physicalFileBytes == before.totals.physicalFileBytes)
        let encoded = try JSONEncoder().encode(after)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("Private content"))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        let contents = try #require(entries.first?["contents"] as? [String: Any])
        #expect(contents["attachmentCount"] == nil)
        #expect(contents["attachmentBytes"] == nil)
    }

    @Test func inventoryBoundsEntriesAndBytesButTotalsIncludeDroppedAndUnknownRecords() throws {
        let host = UUID()
        var inventory = CheckpointInventory(hostID: host, cacheBudgetBytes: 64, primaryBudgetBytes: 512)
        for _ in 0..<150 {
            inventory.include(.init(conversationID: UUID(), threadID: nil, protected: nil, retained: false, invalidation: nil,
                primaryPayloadBytes: 1, cacheBytes: 2, physicalFileBytes: 3, contents: nil))
        }
        #expect(inventory.entries.count == 128)
        #expect(inventory.droppedRecords == 22)
        #expect(inventory.totals.records == 150)
        #expect(inventory.totals.physicalFileBytes == 450)
        #expect(inventory.totals.unknownProtectionRecords == 150)
        #expect(inventory.totals.historyItemCount == nil)
        #expect(inventory.totals.sizeDistributions.unknownProtection.physicalFileBytes == [0, 150, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(try JSONEncoder().encode(inventory).count < CheckpointInventory.byteLimit)

        var large = CheckpointInventory(hostID: host, cacheBudgetBytes: 64, primaryBudgetBytes: 512)
        let state = ConversationState(conversationID: UUID(), threadID: String(repeating: "\n", count: 800))
        for _ in 0..<128 {
            large.include(.init(conversationID: UUID(), threadID: state.threadID, protected: false, retained: false, invalidation: nil,
                primaryPayloadBytes: 0, cacheBytes: 10, physicalFileBytes: 10, contents: .init(state.checkpoint)))
        }
        #expect(large.droppedRecords > 0)
        #expect(large.entries.count + large.droppedRecords == 128)
        #expect(large.totals.physicalFileBytes == 1_280)
        #expect(try JSONEncoder().encode(large).count < CheckpointInventory.byteLimit)
    }

    @Test func protectedRecordsPrecedeLargerUnprotectedRecordsAndSortByPhysicalSize() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 2_000_000)
        var small = ConversationState(conversationID: UUID(), threadID: "small-protected")
        small.submit(ChatMessage(role: .user, text: "small"))
        var large = ConversationState(conversationID: UUID(), threadID: "large-protected")
        large.submit(ChatMessage(role: .user, text: String(repeating: "x", count: 32_768)))
        var remote = ConversationState(conversationID: UUID(), threadID: "large-unprotected")
        remote.merge(history(items: [.agentMessage(id: "reply", text: String(repeating: "y", count: 131_072))],
            threadID: "large-unprotected"))
        for state in [small, remote, large] { try await store.save(state.checkpoint, conversationID: state.conversationID) }
        let inventory = try #require(await store.inventory(threadIDs: [:]))
        #expect(inventory.entries.map(\.threadID) == ["large-protected", "small-protected", "large-unprotected"])
        let sizes = inventory.entries.map(\.physicalFileBytes)
        #expect(sizes[0] > sizes[1])
        #expect(sizes[2] > sizes[0])
    }

    @Test func distributionsUseInclusiveUpperBoundsAndSeparateUnknownProtection() {
        var inventory = CheckpointInventory(hostID: UUID(), cacheBudgetBytes: 64, primaryBudgetBytes: 512)
        for protection: Bool? in [true, false, nil] {
            for bytes in [0, 1_024, 1_025, 268_435_457] {
                inventory.include(.init(conversationID: UUID(), threadID: nil, protected: protection,
                    retained: false, invalidation: nil, primaryPayloadBytes: 0, cacheBytes: bytes,
                    physicalFileBytes: bytes, contents: nil))
            }
        }
        let distributions = inventory.totals.sizeDistributions
        for counts in [distributions.protected, distributions.unprotected, distributions.unknownProtection] {
            #expect(counts.physicalFileBytes == [1, 1, 1, 0, 0, 0, 0, 0, 0, 1])
            #expect(counts.primaryPayloadBytes == [4, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        }
    }

    @Test func loadedIndexSuppliesExactIdentitiesWithoutReadingDiskAndOmitsAmbiguity() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = HostStorage(root: directory)
        let host = UUID()
        let index = ConversationIndex(hostID: host, storage: storage)
        let id = UUID()
        await index.record(sessionID: "exact-thread", conversationID: id)
        let cold = ConversationIndex(hostID: host, storage: storage)
        #expect(await cold.loadedThreadIDs().isEmpty)
        try FileManager.default.removeItem(at: directory)
        #expect(await index.loadedThreadIDs() == [id: "exact-thread"])
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 1_000_000)
        var state = ConversationState(conversationID: id, threadID: "exact-thread")
        state.submit(ChatMessage(role: .user, text: "pending"))
        let submission = try #require(state.checkpoint.submissions.values.first)
        let record = ConversationCheckpointStore.SubmissionRecord(revision: 1, threadID: "exact-thread", submission: submission)
        try await store.saveSubmission(record, conversationID: id, generation: await store.generation(for: id))
        let inventory = try #require(await store.inventory(threadIDs: await index.loadedThreadIDs()))
        #expect(inventory.entries.first?.contents == nil)
        #expect(inventory.entries.first?.threadID == "exact-thread")
        await index.record(sessionID: "conflicting-thread", conversationID: id)
        #expect(await index.loadedThreadIDs().isEmpty)
        let unknown = try #require(await store.inventory(threadIDs: await index.loadedThreadIDs()))
        #expect(unknown.entries.first?.threadID == nil)
    }

    @Test func outboxFlushesInventoryThroughTheExistingTelemetryBatch() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = DiagnosticsOutbox(directory: directory, logSink: AppLogSink(), deviceLabel: { "synthetic-device" })
        outbox.telemetry.record(.checkpointInventory(.init(hostID: UUID(), cacheBudgetBytes: 64, primaryBudgetBytes: 512)))
        await outbox.drain(reason: "test")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-telemetry.jsonl") }
        let records = try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        } }
        let inventory = try #require(records.first { $0["recordType"] as? String == "checkpointInventory" })
        #expect(inventory["schemaVersion"] as? Int == 1)
        #expect(inventory["seq"] as? Int == 1)
        #expect((inventory["inventory"] as? [String: Any])?["cacheBudgetBytes"] as? Int == 64)
    }
}
