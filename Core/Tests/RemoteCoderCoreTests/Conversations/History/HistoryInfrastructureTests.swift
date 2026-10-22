import Foundation
import Testing
@testable import RemoteCoderCore

struct HistoryInfrastructureTests {
    @Test func freshReadDoesNotJoinOrCancelAnOlderReadOfTheSamePage() async throws {
        let scheduler = HistoryReadScheduler()
        let gate = ReadGate()
        let page = key("same")
        let older = Task { try await scheduler.read(key: page, priority: .foreground) { await gate.read("older") } }
        try await eventually { await gate.started == ["older"] }
        let fresh = Task { try await scheduler.readFresh(key: page, priority: .reconciliation) { await gate.read("fresh") } }
        try await eventually { await gate.started == ["older", "fresh"] }
        #expect(await scheduler.statistics(hostID: "host").running == 2)
        let joined = Task { try await scheduler.read(key: page, priority: .foreground) {
            Issue.record("A coalesced caller started another operation")
            return Data()
        } }
        try await eventually { await scheduler.statistics(hostID: "host").waiters == 3 }
        await gate.release("fresh", data: Data([2]))
        let freshPage = try await fresh.value
        #expect(freshPage.data == Data([2]))
        #expect(await scheduler.statistics(hostID: "host").waiters == 2)
        await gate.release("older", data: Data([1]))
        let olderPage = try await older.value
        let joinedPage = try await joined.value
        #expect(olderPage.data == Data([1]))
        #expect(joinedPage.data == olderPage.data)
        #expect(joinedPage.startedAt == olderPage.startedAt)
        #expect(olderPage.startedAt < freshPage.startedAt)
    }

    @Test func independentReadsPublishPagesAndMaterializedTailsInReadStartOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory)
        let gateway = OrderedHistoryGateway()
        let service = GatewayHistoryService(gateway: gateway, cache: cache)
        let header = ConversationHeader.historyFixture()
        let older = Task { try await service.openTail(header: header, base: nil, bypassCache: true) }
        try await eventually { await gateway.pendingItems == 1 }
        let newer = Task { try await service.openTail(header: header, base: nil, bypassCache: true) }
        try await eventually { await gateway.pendingItems == 2 }
        await gateway.releaseItems(1, text: "newer")
        let newerSnapshot = try await newer.value
        #expect(newerSnapshot.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "newer")])
        await gateway.releaseItems(0, text: "older")
        let olderSnapshot = try await older.value
        #expect(olderSnapshot.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "older")])
        let cached = try #require(await service.cachedConversation(header: header))
        #expect(cached.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "newer")])
        let read = try await service.openTail(header: header, base: nil)
        #expect(read.source == .cachedPages)
        #expect(read.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "newer")])
        #expect(await gateway.itemRequests == 2)
        let persisted = try #require(await GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory)).cachedConversation(header: header))
        #expect(persisted.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "newer")])
    }

    @Test func diskIndexRecoversAfterDirectoryBecomesAvailable() async throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = parent.appendingPathComponent("cache")
        let backup = parent.appendingPathComponent("backup")
        let key = key("recover")
        let original = HistoryPageCache(directory: directory)
        try await original.store(Data("durable".utf8), for: key, startedAt: .now, readStartedAt: .now)
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("blocking-file".utf8).write(to: directory)
        let reader = HistoryPageCache(directory: directory)
        #expect(await reader.value(for: key) == nil)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        #expect(await reader.value(for: key)?.data == Data("durable".utf8))
    }

    @Test func failedDiskReplacementStillServesFreshMemoryAndCanRecover() async throws {
        let directory = temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let key = key("replacement")
        let cache = HistoryPageCache(directory: directory)
        try await cache.store(Data("old".utf8), for: key, startedAt: .now, readStartedAt: .now)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        try await cache.store(Data("new".utf8), for: key, startedAt: .now, readStartedAt: .now)
        #expect(await cache.value(for: key)?.data == Data("new".utf8))
        #expect(await HistoryPageCache(directory: directory).value(for: key)?.data == Data("old".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try await cache.store(Data("new".utf8), for: key, startedAt: .now, readStartedAt: .now)
        let reloaded = HistoryPageCache(directory: directory)
        #expect(await reloaded.value(for: key)?.data == Data("new".utf8))
    }

    @Test func cachedReadsAndUnchangedRefreshesDoNotTouchDisk() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory)
        let key = key("page", generation: 1)
        let first = Date(timeIntervalSince1970: 1000)
        try await cache.store(Data("page".utf8), for: key, fetchedAt: first, startedAt: .now, readStartedAt: .now)
        let url = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try FileManager.default.setAttributes([.modificationDate: first], ofItemAtPath: url.path)
        let before = try FileIdentity(url)
        for offset in 1...30 {
            let now = first.addingTimeInterval(Double(offset))
            #expect(await cache.value(for: key, now: now)?.data == Data("page".utf8))
            try await cache.store(Data("page".utf8), for: key, fetchedAt: now, startedAt: .now, readStartedAt: .now)
        }
        #expect(try FileIdentity(url) == before)
        #expect(await cache.value(for: key, now: first.addingTimeInterval(320))?.isFresh == true)
        // Persisted freshness stays conservative after a cold launch.
        #expect(await HistoryPageCache(directory: directory).value(for: key, now: first.addingTimeInterval(320))?.isFresh == false)
    }

    @Test func pageRequestsKeepIndependentFreshnessAcrossRelaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory)
        let older = key("partial")
        let newer = key("full")
        let fetchedAt = Date(timeIntervalSince1970: 1000)
        try await cache.store(Data("partial".utf8), for: older, fetchedAt: fetchedAt, startedAt: .now, readStartedAt: .now)
        try await cache.store(Data("full".utf8), for: newer, fetchedAt: fetchedAt.addingTimeInterval(150), startedAt: .now, readStartedAt: .now)
        #expect(await cache.value(for: older, now: fetchedAt.addingTimeInterval(299))?.isFresh == true)
        let reloaded = HistoryPageCache(directory: directory)
        let stale = await reloaded.value(for: older, now: fetchedAt.addingTimeInterval(300))
        #expect(stale?.data == Data("partial".utf8))
        #expect(stale?.isFresh == false)
        #expect(await reloaded.value(for: newer, now: fetchedAt.addingTimeInterval(300))?.isFresh == true)
        #expect(await reloaded.value(for: self.key("different-detail"), now: fetchedAt) == nil)
    }

    @Test func cacheSeparatesHostsAndGenerationsAndInvalidatesThreadOnDisk() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory)
        let first = key("page", host: "first")
        let second = key("page", host: "second")
        try await cache.store(Data([1]), for: first, startedAt: .now, readStartedAt: .now)
        try await cache.store(Data([2]), for: second, startedAt: .now, readStartedAt: .now)
        #expect(await cache.value(for: key("page", host: "first", generation: 1)) == nil)
        await cache.invalidate(threadID: "thread", hostID: "first")
        let reloaded = HistoryPageCache(directory: directory)
        #expect(await reloaded.value(for: first) == nil)
        #expect(await reloaded.value(for: second)?.data == Data([2]))
        await reloaded.invalidate(hostID: "second")
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func memoryEvictsLeastRecentlyUsedBytesAndDoesNotRetainOversizedPage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory, memoryBudgetBytes: 6, diskBudgetBytes: 0)
        try await cache.store(Data([1, 1, 1]), for: key("one"), startedAt: .now, readStartedAt: .now)
        try await cache.store(Data([2, 2, 2]), for: key("two"), startedAt: .now, readStartedAt: .now)
        _ = await cache.value(for: key("one"))
        try await cache.store(Data([3, 3, 3]), for: key("three"), startedAt: .now, readStartedAt: .now)
        #expect(await cache.value(for: key("two")) == nil)
        #expect(await cache.value(for: key("one"))?.data == Data([1, 1, 1]))
        #expect(await cache.totalMemoryBytes == 6)
        try await cache.store(Data(repeating: 0, count: 7), for: key("large"), startedAt: .now, readStartedAt: .now)
        #expect(await cache.value(for: key("large")) == nil)
        #expect(await cache.totalMemoryBytes == 6)
    }

    @Test func diskBudgetIncludesEnvelopeAndEvictionSurvivesRelaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory, memoryBudgetBytes: 2000, diskBudgetBytes: 2600)
        try await cache.store(Data(repeating: 1, count: 1000), for: key("one"), startedAt: .now, readStartedAt: .now)
        try await cache.store(Data(repeating: 2, count: 1000), for: key("two"), startedAt: .now, readStartedAt: .now)
        try await cache.store(Data(repeating: 3, count: 1000), for: key("three"), startedAt: .now, readStartedAt: .now)
        #expect(try diskBytes(in: directory) <= 2600)
        let reloaded = HistoryPageCache(directory: directory, memoryBudgetBytes: 2000, diskBudgetBytes: 2600)
        #expect(await reloaded.value(for: key("one")) == nil)
        #expect(await reloaded.value(for: key("three"))?.data == Data(repeating: 3, count: 1000))
        #expect(try diskBytes(in: directory) <= 2600)
    }

    @Test func corruptAndObsoleteEnvelopesAreCacheMisses() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory)
        try await cache.store(Data([1]), for: key("page"), startedAt: .now, readStartedAt: .now)
        let url = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var envelope = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        envelope["version"] = 0
        try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0).write(to: url)
        #expect(await HistoryPageCache(directory: directory).value(for: key("page")) == nil)
        try Data("broken".utf8).write(to: url)
        #expect(await HistoryPageCache(directory: directory).value(for: key("page")) == nil)
    }

    @Test func manyCallersShareOneReadAndCancellingOnePreservesOthers() async throws {
        let scheduler = HistoryReadScheduler()
        let gate = ReadGate()
        let page = key("same")
        let tasks = (0..<24).map { _ in
            Task { try await scheduler.read(key: page, priority: .foreground) { await gate.read("same") } }
        }
        try await eventually { await scheduler.statistics(hostID: "host").waiters == 24 }
        try await eventually { await gate.started == ["same"] }
        tasks[0].cancel()
        do {
            _ = try await tasks[0].value
            Issue.record("Cancelled waiter returned a result")
        } catch { #expect(error is CancellationError) }
        #expect(await scheduler.statistics(hostID: "host").waiters == 23)
        await gate.release("same", data: Data([7]))
        for task in tasks.dropFirst() { #expect(try await task.value.data == Data([7])) }
        #expect(await scheduler.statistics(hostID: "host").running == 0)
    }

    @Test func cancelledOperationCannotCompleteReplacementWithSameKey() async throws {
        let scheduler = HistoryReadScheduler()
        let gate = ReadGate()
        let page = key("same")
        let original = Task { try await scheduler.read(key: page, priority: .foreground) { await gate.read("old") } }
        try await eventually { await gate.started == ["old"] }
        original.cancel()
        do { _ = try await original.value; Issue.record("Cancellation was lost") }
        catch { #expect(error is CancellationError) }
        let replacement = Task { try await scheduler.read(key: page, priority: .foreground) { await gate.read("new") } }
        try await eventually { await gate.started == ["old", "new"] }
        await gate.release("old", data: Data([0]))
        try await eventually { await scheduler.statistics(hostID: "host").running == 1 }
        #expect(await scheduler.statistics(hostID: "host").waiters == 1)
        await gate.release("new", data: Data([1]))
        #expect(try await replacement.value.data == Data([1]))
    }

    @Test func pendingPrefetchPromotesAndForegroundUsesReservedSlot() async throws {
        let scheduler = HistoryReadScheduler()
        let gate = ReadGate()
        let first = Task { try await scheduler.read(key: key("first"), priority: .prefetch) { await gate.read("first") } }
        try await eventually { await gate.started == ["first"] }
        let pending = Task { try await scheduler.read(key: key("pending"), priority: .prefetch) { await gate.read("pending") } }
        try await eventually { await scheduler.statistics(hostID: "host").pending == 1 }
        #expect(await gate.started == ["first"])
        let promoted = Task { try await scheduler.read(key: key("pending"), priority: .foreground) { Issue.record("Duplicate operation"); return Data() } }
        try await eventually { await gate.started == ["first", "pending"] }
        #expect(await scheduler.statistics(hostID: "host").running == 2)
        #expect(await scheduler.statistics(hostID: "host").waiters == 3)
        await gate.release("first", data: Data([1]))
        await gate.release("pending", data: Data([2]))
        #expect(try await first.value.data == Data([1]))
        #expect(try await pending.value.data == Data([2]))
        #expect(try await promoted.value.data == Data([2]))
    }

    @Test func allWaitersCancellationRetainsCapacityUntilUnderlyingReadEnds() async throws {
        let scheduler = HistoryReadScheduler()
        let gate = ReadGate()
        let first = Task { try await scheduler.read(key: key("one"), priority: .foreground) { await gate.read("one") } }
        let second = Task { try await scheduler.read(key: key("two"), priority: .foreground) { await gate.read("two") } }
        try await eventually { await gate.started.count == 2 }
        await scheduler.invalidate(hostID: "host")
        for task in [first, second] {
            do { _ = try await task.value; Issue.record("Invalidated caller succeeded") }
            catch { #expect(error as? HistoryReadFailure == .invalidated) }
        }
        let third = Task { try await scheduler.read(key: key("three"), priority: .foreground) { await gate.read("three") } }
        try await eventually { await scheduler.statistics(hostID: "host").pending == 1 }
        #expect(await gate.started.count == 2)
        #expect(await scheduler.statistics(hostID: "host").running == 2)
        await gate.release("one", data: Data())
        try await eventually { await gate.started.contains("three") }
        await gate.release("two", data: Data())
        await gate.release("three", data: Data([3]))
        #expect(try await third.value.data == Data([3]))
    }

    @Test func cancellingPendingCallerNeverStartsItsReadAndHostsHaveIndependentCapacity() async throws {
        let scheduler = HistoryReadScheduler()
        let gate = ReadGate()
        let first = Task { try await scheduler.read(key: key("one"), priority: .prefetch) { await gate.read("one") } }
        try await eventually { await gate.started == ["one"] }
        let pending = Task { try await scheduler.read(key: key("cancelled"), priority: .prefetch) { Issue.record("Cancelled pending read started"); return Data() } }
        try await eventually { await scheduler.statistics(hostID: "host").pending == 1 }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancellation was lost") }
        catch { #expect(error is CancellationError) }
        let otherHost = Task { try await scheduler.read(key: key("two", host: "other"), priority: .prefetch) { await gate.read("two") } }
        try await eventually { await gate.started == ["one", "two"] }
        #expect(await scheduler.statistics(hostID: "host").pending == 0)
        #expect(await scheduler.statistics(hostID: "other").running == 1)
        await gate.release("one", data: Data([1]))
        await gate.release("two", data: Data([2]))
        #expect(try await first.value.data == Data([1]))
        #expect(try await otherHost.value.data == Data([2]))
    }

    @Test func failedReadDoesNotPoisonNextAttempt() async throws {
        let scheduler = HistoryReadScheduler()
        do {
            _ = try await scheduler.read(key: key("failure"), priority: .foreground) { throw ProbeFailure.expected }
            Issue.record("Expected read to fail")
        } catch { #expect(error is ProbeFailure) }
        #expect(try await scheduler.read(key: key("failure"), priority: .foreground) { Data([1]) }.data == Data([1]))
    }

    private nonisolated func key(_ request: String, host: String = "host", generation: UInt64 = 0) -> HistoryPageKey {
        HistoryPageKey(hostID: host, provider: "codex", threadID: "thread", generation: generation, request: request)
    }

    private nonisolated func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private nonisolated func diskBytes(in directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).reduce(0) { total, url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return total + (try #require(attributes[.size] as? NSNumber)).intValue
        }
    }



}

private nonisolated enum ProbeFailure: Error { case expected }

private actor ReadGate {
    private(set) var started: [String] = []
    private var pending: [String: CheckedContinuation<Data, Never>] = [:]

    func read(_ name: String) async -> Data {
        started.append(name)
        return await withCheckedContinuation { pending[name] = $0 }
    }

    func release(_ name: String, data: Data) {
        pending.removeValue(forKey: name)?.resume(returning: data)
    }
}

private actor OrderedHistoryGateway: CodexHistoryGateway {
    let historyHostID = "host"
    private var items: [Int: CheckedContinuation<Data, any Error>] = [:]
    private(set) var itemRequests = 0
    var pendingItems: Int { items.count }

    func historyPageData(method: String, params: JSONValue) async throws -> Data {
        if method == "thread/turns/list" {
            return try JSONEncoder().encode(HistoryEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(
                data: [.init(id: "turn", items: [], startedAt: 1, completedAt: 2, status: .completed, error: nil)],
                nextCursor: nil, backwardsCursor: nil)))
        }
        guard method == "thread/items/list" else { throw ProbeFailure.expected }
        let id = itemRequests
        itemRequests += 1
        return try await withCheckedThrowingContinuation { items[id] = $0 }
    }

    func releaseItems(_ id: Int, text: String) {
        do {
            let response = CodexAppServerV2.ThreadItemsListResponse(data: [.init(turnId: "turn",
                item: .agentMessage(id: "reply", text: text), startedAtOrdinal: 1, isComplete: true)],
                nextCursor: nil, backwardsCursor: nil)
            items.removeValue(forKey: id)?.resume(returning: try JSONEncoder().encode(HistoryEnvelope(result: response)))
        } catch { items.removeValue(forKey: id)?.resume(throwing: error) }
    }

    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse { throw ProbeFailure.expected }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw ProbeFailure.expected }
    func readThread(threadID: String, includeTurns: Bool) -> CodexAppServerV2.ThreadReadResponse {
        .init(thread: .historyFixture(id: threadID))
    }
}

private nonisolated struct HistoryEnvelope<Value: Encodable>: Encodable {
    let result: Value
}
