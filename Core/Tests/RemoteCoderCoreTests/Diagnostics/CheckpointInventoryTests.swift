import Foundation
import Testing
@testable import RemoteCoderCore

struct CheckpointInventoryTests {
    @Test(arguments: [false, true])
    func inventoryUsesLoadedBookkeepingAfterFilesBecomeUnreadable(cold: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID()
        let store = ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 1_000_000)
        #expect(await store.inventory() == nil)
        var state = ConversationState(conversationID: UUID(), threadID: "synthetic-thread")
        state.submit(ChatMessage(role: .user, text: "Private content must never appear in telemetry"))
        try await store.save(state.checkpoint, conversationID: state.conversationID)
        let observer = cold ? ConversationCheckpointStore(hostID: host, directory: directory, primaryBudgetBytes: 1_000_000) : store
        if cold { _ = try await observer.load(state.conversationID) }
        let before = try #require(await observer.inventory())
        let entry = try #require(before.entries.first)
        #expect(before.hostID == host)
        #expect(before.totals.records == 1)
        #expect(entry.contents?.threadID == "synthetic-thread")
        #expect(entry.contents?.turnCount == 1)
        #expect(entry.protected == true)
        #expect(entry.primaryPayloadBytes > 0)
        try FileManager.default.removeItem(at: directory)
        let after = try #require(await observer.inventory())
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
            inventory.include(.init(conversationID: UUID(), protected: nil, retained: false, invalidation: nil,
                primaryPayloadBytes: 1, cacheBytes: 2, physicalFileBytes: 3, contents: nil))
        }
        #expect(inventory.entries.count == 128)
        #expect(inventory.droppedRecords == 22)
        #expect(inventory.totals.records == 150)
        #expect(inventory.totals.physicalFileBytes == 450)
        #expect(inventory.totals.unknownProtectionRecords == 150)
        #expect(inventory.totals.historyItemCount == nil)
        #expect(try JSONEncoder().encode(inventory).count < CheckpointInventory.byteLimit)

        var large = CheckpointInventory(hostID: host, cacheBudgetBytes: 64, primaryBudgetBytes: 512)
        let state = ConversationState(conversationID: UUID(), threadID: String(repeating: "\n", count: 800))
        for _ in 0..<128 {
            large.include(.init(conversationID: UUID(), protected: false, retained: false, invalidation: nil,
                primaryPayloadBytes: 0, cacheBytes: 10, physicalFileBytes: 10, contents: .init(state.checkpoint)))
        }
        #expect(large.droppedRecords > 0)
        #expect(large.entries.count + large.droppedRecords == 128)
        #expect(large.totals.physicalFileBytes == 1_280)
        #expect(try JSONEncoder().encode(large).count < CheckpointInventory.byteLimit)
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
