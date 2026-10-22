import Foundation
import Synchronization
import Testing
@testable import RemoteCoderCore

struct HistoryEntryPointFenceTests {
    enum Invalidation: CaseIterable, Sendable { case thread, all, evicted }

    @Test(arguments: Invalidation.allCases)
    func aRefreshHeldInReadHeaderCannotAdoptANewFence(_ invalidation: Invalidation) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = EntryPointFenceGateway()
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        await gateway.holdHeader()
        let read = Task { try await service.refreshTail(threadID: "held", base: nil, bypassCache: true) }
        defer { await gateway.releaseHeader(); _ = await read.result }
        await gateway.waitForHeader()
        await invalidate(service, with: invalidation)
        await gateway.releaseHeader()
        switch await read.result {
        case .success: Issue.record("A refresh held in readHeader published after invalidation")
        case .failure(let error): #expect(error as? HistoryReadFailure == .invalidated)
        }
        #expect(await gateway.itemReads == 0)
        let fresh = try await service.refreshTail(threadID: "held", base: nil, bypassCache: true)
        #expect(fresh.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "current")])
    }

    @Test(arguments: Invalidation.allCases)
    func aCachedTailHeldBeforeDecodeCannotPublishAfterInvalidation(_ invalidation: Invalidation) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory)
        let header = ConversationHeader.historyFixture(id: "held")
        var window = HistoryWindow()
        window.apply(.init(items: .init(elements: [.init(turnId: "turn", item: .agentMessage(id: "cached", text: "old"),
            startedAtOrdinal: 1, isComplete: true)], older: nil, newer: nil, fetchedAt: .now), placement: .tail, metadata: []))
        let key = HistoryPageKey(hostID: "host", provider: "native", threadID: header.id, generation: 0, request: "native-v4:tail")
        let startedAt = ContinuousClock.now
        try await cache.store(try JSONEncoder().encode(window), for: key, startedAt: startedAt, readStartedAt: startedAt)
        let executor = ManualTaskExecutor()
        let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let firstValue = Mutex(true)
        let gateway = EntryPointFenceGateway()
        let service = GatewayHistoryService(gateway: gateway, cache: cache, now: {
            if firstValue.withLock({ first in let shouldPause = first; first = false; return shouldPause }) {
                executor.pause()
                entered.continuation.yield()
                entered.continuation.finish()
            }
            return .now
        })
        let read = Task(executorPreference: executor, priority: .background) { await service.cachedConversation(header: header) }
        defer { executor.resume(); _ = await read.result }
        var arrivals = entered.stream.makeAsyncIterator()
        try #require(await arrivals.next() != nil)
        try await executor.waitForJob()
        try await executor.runNext()
        try await executor.waitForJob()
        try await executor.runNext()
        try await executor.waitForJob()
        let invalidationTask = Task(priority: .high) { await invalidate(service, with: invalidation) }
        await invalidationTask.value
        executor.resume()
        #expect(await read.value == nil)
        let fresh = try await service.openTail(header: header, base: nil, bypassCache: true)
        #expect(fresh.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "current")])
        let cached = try #require(await service.cachedConversation(header: header))
        #expect(cached.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "current")])
    }

    private func invalidate(_ service: GatewayHistoryService, with invalidation: Invalidation) async {
        switch invalidation {
        case .thread: await service.invalidate(threadID: "held")
        case .all: await service.invalidateAll()
        case .evicted:
            for index in 0..<65 { await service.invalidate(threadID: "unrelated-\(index)") }
        }
    }
}

private actor EntryPointFenceGateway: CodexHistoryGateway {
    let historyHostID = "host"
    private var holdsHeader = false
    private var heldHeader: CheckedContinuation<Void, Never>?
    private var headerArrival: CheckedContinuation<Void, Never>?
    private(set) var itemReads = 0

    func holdHeader() { holdsHeader = true }
    func waitForHeader() async {
        guard heldHeader == nil else { return }
        await withCheckedContinuation { headerArrival = $0 }
    }
    func releaseHeader() {
        holdsHeader = false
        heldHeader?.resume()
        heldHeader = nil
    }

    func historyPageData(method: String, params: JSONValue) throws -> Data {
        if method == "thread/items/list" {
            itemReads += 1
            return try JSONEncoder().encode(EntryPointFenceEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(
                data: [.init(turnId: "turn", item: .agentMessage(id: "reply", text: "current"), startedAtOrdinal: 1, isComplete: true)],
                nextCursor: nil, backwardsCursor: nil)))
        }
        guard method == "thread/turns/list" else { throw GatewayClient.ClientError.invalidMessage }
        return try JSONEncoder().encode(EntryPointFenceEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(
            data: [.init(id: "turn", items: [], startedAt: 1, completedAt: 2, status: .completed, error: nil)],
            nextCursor: nil, backwardsCursor: nil)))
    }

    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse {
        throw GatewayClient.ClientError.invalidMessage
    }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw GatewayClient.ClientError.invalidMessage }
    func readThread(threadID: String, includeTurns: Bool) async -> CodexAppServerV2.ThreadReadResponse {
        if holdsHeader {
            await withCheckedContinuation { heldHeader = $0; headerArrival?.resume(); headerArrival = nil }
        }
        return .init(thread: .historyFixture(id: threadID))
    }
}

private nonisolated struct EntryPointFenceEnvelope<Value: Encodable>: Encodable { let result: Value }
