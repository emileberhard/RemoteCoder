import Foundation
import Testing
@testable import RemoteCoderCore

struct HistoryInvalidationCacheTests {
    enum Scope: CaseIterable, Sendable { case thread, host, evicted }

    @Test(arguments: Scope.allCases)
    func invalidationRejectsAnOlderWriteEvenAfterItsEntryAndFenceWereRemoved(_ scope: Scope) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory)
        let key = HistoryPageKey(hostID: "host", provider: "native", threadID: "held", generation: 0, request: "tail")
        let startedAt = ContinuousClock.now
        try await cache.store(Data("original".utf8), for: key, startedAt: startedAt, readStartedAt: startedAt)
        let executor = ManualTaskExecutor()
        let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let writer = Task(executorPreference: executor, priority: .background) {
            executor.pause()
            entered.continuation.yield()
            entered.continuation.finish()
            try await cache.store(Data("stale".utf8), for: key, startedAt: startedAt, readStartedAt: startedAt)
        }
        defer { executor.resume(); _ = await writer.result }
        var arrivals = entered.stream.makeAsyncIterator()
        try #require(await arrivals.next() != nil)
        try await executor.waitForJob()
        let invalidation = Task(priority: .high) {
            switch scope {
            case .host: await cache.invalidate(hostID: key.hostID)
            case .thread, .evicted: await cache.invalidate(threadID: key.threadID, hostID: key.hostID)
            }
            if scope == .evicted {
                for index in 0..<64 { await cache.invalidate(threadID: "other-\(index)", hostID: key.hostID) }
            }
        }
        await invalidation.value
        executor.resume()
        switch await writer.result {
        case .success: Issue.record("An invalidated read repopulated the cache")
        case .failure(let error): #expect(error as? HistoryReadFailure == .invalidated)
        }
        #expect(await cache.value(for: key) == nil)
        #expect(await HistoryPageCache(directory: directory).value(for: key) == nil)
        try await cache.store(Data("current".utf8), for: key, startedAt: .now, readStartedAt: .now)
        #expect(await cache.value(for: key)?.data == Data("current".utf8))
        #expect(await HistoryPageCache(directory: directory).value(for: key)?.data == Data("current".utf8))
    }

    @Test func aRetainedCachedPageCanBeReusedAfterUnrelatedInvalidationMetadataEviction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = InvalidationCacheGateway()
        let cache = HistoryPageCache(directory: directory)
        let service = GatewayHistoryService(gateway: gateway, cache: cache)
        let header = ConversationHeader.historyFixture(id: "held")
        let initial = Task { try await service.openTail(header: header, base: nil) }
        defer { await gateway.releaseItems(); _ = await initial.result }
        await gateway.waitForItems()
        await gateway.releaseItems()
        let stored = try await initial.value
        for index in 0..<65 { await service.invalidate(threadID: "unrelated-\(index)") }
        let reused = try await service.openTail(header: header, base: stored.window)
        #expect(reused.window.turns.flatMap { $0.entries.map(\.item) } == stored.window.turns.flatMap { $0.entries.map(\.item) })
        #expect(await gateway.itemRequests == 1)
    }

    @Test func aRejectedPageCannotWarmTheNextNonBypassingRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = InvalidationCacheGateway()
        let cache = HistoryPageCache(directory: directory)
        let service = GatewayHistoryService(gateway: gateway, cache: cache)
        let header = ConversationHeader.historyFixture(id: "held")
        let read = Task { try await service.openTail(header: header, base: nil, bypassCache: true) }
        defer { await gateway.releaseItems(); _ = await read.result }
        await gateway.waitForItems()
        await cache.invalidate(threadID: header.id, hostID: "host")
        await gateway.releaseItems()
        switch await read.result {
        case .success: Issue.record("A read whose cache authority was invalidated published a snapshot")
        case .failure(let error): #expect(error as? HistoryReadFailure == .invalidated)
        }
        #expect(await service.cachedConversation(header: header) == nil)
        #expect(await GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
            .cachedConversation(header: header) == nil)
        let fresh = try await service.openTail(header: header, base: nil)
        #expect(fresh.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "current")])
        #expect(await gateway.itemRequests == 2)
        let restored = try #require(await GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
            .cachedConversation(header: header))
        #expect(restored.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "current")])
    }
}

private actor InvalidationCacheGateway: CodexHistoryGateway {
    let historyHostID = "host"
    private var held: (data: Data, continuation: CheckedContinuation<Data, Never>)?
    private var arrival: CheckedContinuation<Void, Never>?
    private(set) var itemRequests = 0

    func waitForItems() async {
        guard held == nil else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func releaseItems() {
        guard let held else { return }
        self.held = nil
        held.continuation.resume(returning: held.data)
    }

    func historyPageData(method: String, params: JSONValue) async throws -> Data {
        if method == "thread/items/list" {
            itemRequests += 1
            let data = try JSONEncoder().encode(InvalidationCacheEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(
                data: [.init(turnId: "turn", item: .agentMessage(id: "reply", text: itemRequests == 1 ? "stale" : "current"),
                    startedAtOrdinal: 1, isComplete: true)], nextCursor: nil, backwardsCursor: nil)))
            guard itemRequests == 1 else { return data }
            return await withCheckedContinuation { continuation in
                held = (data, continuation)
                arrival?.resume()
                arrival = nil
            }
        }
        guard method == "thread/turns/list" else { throw GatewayClient.ClientError.invalidMessage }
        return try JSONEncoder().encode(InvalidationCacheEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(
            data: [.init(id: "turn", items: [], startedAt: 1, completedAt: 2, status: .completed, error: nil)],
            nextCursor: nil, backwardsCursor: nil)))
    }

    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse {
        throw GatewayClient.ClientError.invalidMessage
    }

    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw GatewayClient.ClientError.invalidMessage }

    func readThread(threadID: String, includeTurns: Bool) -> CodexAppServerV2.ThreadReadResponse {
        .init(thread: .historyFixture(id: threadID))
    }
}

private nonisolated struct InvalidationCacheEnvelope<Value: Encodable>: Encodable {
    let result: Value
}
