import Darwin
import Foundation
import Synchronization
import Testing
@testable import RemoteCoderCore

@Suite(.serialized)
struct HistoryCacheWriteTests {
    @Test func unchangedTailRefreshesPreserveDiskAndColdReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = try CacheWriteGateway()
        let cache = HistoryPageCache(directory: directory)
        let service = GatewayHistoryService(gateway: gateway, cache: cache)
        let header = ConversationHeader.historyFixture(id: "cache-writes")
        let before = PersistenceMetrics.shared.snapshot()[.historyPages] ?? .init()
        let cpu = clock()
        var snapshot = try await service.openTail(header: header, base: nil, bypassCache: true)
        let files = try identities(directory)
        for _ in 0..<20 {
            snapshot = try await service.openTail(header: header, base: snapshot.window, bypassCache: true)
        }
        let after = PersistenceMetrics.shared.snapshot()[.historyPages] ?? .init()
        print("TAIL_REFRESH_MEASUREMENT writes=\(after.writes - before.writes) bytes=\(after.bytes - before.bytes) cpu_ms=\(Double(clock() - cpu) * 1000 / Double(CLOCKS_PER_SEC))")
        #expect(try identities(directory) == files)
        #expect(files.count == 1)
        let cold = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let restored = try #require(await cold.cachedConversation(header: header))
        #expect(restored.window.turns.flatMap { $0.entries.map(\.item) } == snapshot.window.turns.flatMap { $0.entries.map(\.item) })
        #expect(restored.window.older == "older-opaque")
        _ = try await cold.openTail(header: header, base: restored.window, bypassCache: true)
        #expect(try identities(directory) == files)
        #expect(snapshot.window.encodedBytes > 400_000)
        let fresh = try await service.openTail(header: header, base: nil)
        #expect(fresh.source == .cachedPages)
        #expect(await gateway.itemReads == 22)
        await gateway.changeReplies()
        let changed = try await service.openTail(header: header, base: snapshot.window, bypassCache: true)
        #expect(changed.window.turns.flatMap { $0.entries.map(\.item) } != snapshot.window.turns.flatMap { $0.entries.map(\.item) })
        let changedCold = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let changedStored = try #require(await changedCold.cachedConversation(header: header))
        #expect(changedStored.window.turns.flatMap { $0.entries.map(\.item) } == changed.window.turns.flatMap { $0.entries.map(\.item) })
        await service.invalidate(threadID: header.id)
        #expect(await service.cachedConversation(header: header) == nil)
        #expect(try identities(directory).isEmpty)
    }

    @Test func olderPagesRetainExactResultBytesWithoutTransportMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = try CacheWriteGateway()
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let header = ConversationHeader.historyFixture(id: "older-cache")
        let tail = try await service.openTail(header: header, base: nil)
        let resultBytes = await gateway.payloads.reduce(0) { $0 + $1.count - 11 }
        #expect(tail.window.encodedBytes == resultBytes)
        let older = try await service.page(header: header, window: tail.window, direction: .desc, priority: .foreground)
        #expect(older.window.older == nil)
        let payloads = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { url in
            let envelope = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            return try #require(envelope["data"] as? Data)
        }
        let raw = try #require(payloads.first { String(decoding: $0, as: UTF8.self).contains("futureField") })
        #expect(raw == Data(#"{"data":[],"nextCursor":null,"backwardsCursor":"opaque\\\"}[]é","futureField":{"result":[1e100,{"value":"\\\"}"}]}}"#.utf8))
        let cold = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let again = try await cold.page(header: header, window: tail.window, direction: .desc, priority: .foreground)
        #expect(again.window.older == nil)
        #expect(await gateway.itemReads == 1)
    }

    @Test func restoredTailRejectsOlderOverlappingCachedReplies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = try CacheWriteGateway()
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 1100)
        let date = Mutex(earlier)
        let cache = HistoryPageCache(directory: directory)
        let service = GatewayHistoryService(gateway: gateway, cache: cache, now: { date.withLock { $0 } })
        let header = ConversationHeader.historyFixture(id: "edited-reply")
        try await gateway.useCurrentRepliesForOlderPage()
        let original = try await service.openTail(header: header, base: nil, bypassCache: true)
        _ = try await service.page(header: header, window: original.window, direction: .desc, priority: .foreground)
        date.withLock { $0 = later }
        await gateway.changeReplies()
        let edited = try await service.openTail(header: header, base: nil, bypassCache: true)
        let cold = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory), now: { later })
        let restored = try #require(await cold.cachedConversation(header: header))
        #expect(restored.window.items.pages.first?.fetchedAt == later)
        let paged = try await cold.page(header: header, window: restored.window, direction: .desc, priority: .foreground)
        #expect(paged.source == .cachedPages)
        let preservesEditedReplies = paged.window.turns.flatMap { $0.entries.map(\.item) } == edited.window.turns.flatMap { $0.entries.map(\.item) }
        #expect(preservesEditedReplies)
    }

    private func identities(_ directory: URL) throws -> [String: FileIdentity] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { ($0.lastPathComponent, try FileIdentity($0)) })
    }
}

private actor CacheWriteGateway: CodexHistoryGateway {
    let historyHostID = "cache-write-host"
    private(set) var itemReads = 0
    var payloads: [Data] { [items, turns] }
    private var olderItems: Data?
    private var items: Data
    private let turns: Data

    init() throws {
        let entries = (0..<50).map { index in
            CodexAppServerV2.ThreadItemsListResponse.Entry(turnId: "turn", item: .agentMessage(id: "reply-\(index)", text: String(repeating: "abcdefghij", count: 960)), startedAtOrdinal: index, isComplete: true)
        }
        items = try JSONEncoder().encode(CacheWriteEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(data: entries, nextCursor: "older-opaque", backwardsCursor: nil)))
        turns = try JSONEncoder().encode(CacheWriteEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(data: [.init(id: "turn", items: [], startedAt: 1, completedAt: 2, status: .completed, error: nil)], nextCursor: nil, backwardsCursor: nil)))
    }

    func useCurrentRepliesForOlderPage() throws {
        var envelope = try #require(JSONSerialization.jsonObject(with: items) as? [String: Any])
        var result = try #require(envelope["result"] as? [String: Any])
        result["nextCursor"] = NSNull()
        envelope["result"] = result
        olderItems = try JSONSerialization.data(withJSONObject: envelope)
    }

    func changeReplies() {
        items = Data(String(decoding: items, as: UTF8.self).replacingOccurrences(of: "abcdefghij", with: "changedxxx").utf8)
    }

    func historyPageData(method: String, params: JSONValue) throws -> Data {
        if method == "thread/items/list" {
            if params.objectValue?["cursor"] != nil {
                if let olderItems { return olderItems }
                return Data(#"{"metadata":{"result":"ignored \"}[]"},"re\u0073ult":{"data":[],"nextCursor":null,"backwardsCursor":"opaque\\\"}[]é","futureField":{"result":[1e100,{"value":"\\\"}"}]}},"id":999}"#.utf8)
            }
            itemReads += 1
            return items
        }
        return turns
    }
    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse { throw GatewayClient.ClientError.invalidMessage }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw GatewayClient.ClientError.invalidMessage }
    func readThread(threadID: String, includeTurns: Bool) -> CodexAppServerV2.ThreadReadResponse { .init(thread: .historyFixture(id: threadID)) }
}

private nonisolated struct CacheWriteEnvelope<T: Encodable>: Encodable { let result: T }
