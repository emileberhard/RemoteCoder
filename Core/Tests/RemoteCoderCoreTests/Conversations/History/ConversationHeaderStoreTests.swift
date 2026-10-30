import Foundation
import Synchronization
import Testing
@testable import RemoteCoderCore

struct ConversationHeaderStoreTests {
    @Test(arguments: ["claude_literal", "codex_literal"])
    func literalMarkerPreviewsAreDecodedOnceAcrossProviderAndCacheBoundaries(_ id: String) async throws {
        struct Fixture: Decodable {
            let name: String
            let prompt: String
            let summary: String
        }
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: ProtocolFixtures.data(at: "attachments/pasted-text-v2-cases.json"))
        let literal = try #require(fixtures.first { $0.name == "typed-complete-v2-tag" })
        let preview = id.hasPrefix("claude_") ? literal.summary : literal.prompt
        let header = try thread(id, updatedAt: 2, preview: preview)
        #expect(header.preview == literal.summary)
        #expect(header.displayTitle == literal.summary)

        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var current = header
        for revision in 1...3 {
            let store = ConversationHeaderStore(hostID: nil, directory: directory)
            await store.save(snapshot: .init(threads: [current], lastSuccessfulRefreshAt: nil, revision: UInt64(revision)))
            current = try #require(await ConversationHeaderStore(hostID: nil, directory: directory).load().threads.first)
            #expect(current.preview == literal.summary)
            #expect(current.displayTitle == literal.summary)
        }
    }

    @Test func retirementRetainsHostPinsAndExcludesDelegatedHeaders() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let host = UUID()
        let source = temporary.storage.root.appending(path: "retired-history")
        let pinned = try thread("host-pin", updatedAt: 1)
        await ConversationHeaderStore(hostID: host, storage: temporary.storage)
            .save(snapshot: .init(threads: [pinned], lastSuccessfulRefreshAt: nil, revision: 1))
        var incoming = try (0..<1_024).map { try thread("retired-\($0)", updatedAt: Int64(100 + $0)) }
        var child = try thread("child", updatedAt: 10_000)
        child.agentRelation = .init(parentThreadId: "retired-0", parentAccountId: nil, agentId: "launcher:child")
        incoming.append(child)
        await ConversationHeaderStore(hostID: host, directory: source)
            .save(snapshot: .init(threads: incoming, lastSuccessfulRefreshAt: nil, revision: 1))
        try ConversationHeaderStore.adoptRetiredAccountHistory(from: source.appending(path: "\(host).json"),
            hostID: host, storage: temporary.storage, pinned: Set(incoming.map(\.id)).union([pinned.id]))
        let restored = await ConversationHeaderStore(hostID: host, storage: temporary.storage).load().threads
        #expect(restored.count == 1_024)
        #expect(restored.contains { $0.id == pinned.id })
        #expect(!restored.contains { $0.id == child.id })
    }

    @Test func anOlderCallerSaveCannotReplaceANewerRevisionOnDiskOrInMemory() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationHeaderStore(hostID: nil, directory: directory)
        var old = try thread("same-thread", updatedAt: 1)
        old.name = "Old name"
        var new = old
        new.name = "New name"
        new.lastTurnCompletedAt = 100
        let older = ConversationHeaderStore.Snapshot(threads: [old], lastSuccessfulRefreshAt: nil, revision: 1)
        let newer = ConversationHeaderStore.Snapshot(threads: [new], lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 100),
            hasDiscardedHeaders: true, revision: 2)
        await store.save(snapshot: newer)
        let file = directory.appending(path: "default.json")
        let before = try Data(contentsOf: file)
        await store.save(snapshot: older)
        #expect(try Data(contentsOf: file) == before)
        #expect(await store.load() == newer)
        let reloaded = await ConversationHeaderStore(hostID: nil, directory: directory).load()
        #expect(reloaded == newer)
        let sameRevisionConflict = ConversationHeaderStore.Snapshot(threads: [old], lastSuccessfulRefreshAt: nil, revision: 2)
        await store.save(snapshot: sameRevisionConflict)
        #expect(await store.load() == newer)
        #expect(try Data(contentsOf: file) == before)
        let restarted = ConversationHeaderStore(hostID: nil, directory: directory)
        await restarted.save(snapshot: .init(threads: [old], lastSuccessfulRefreshAt: nil, revision: reloaded.revision + 1))
        #expect(await restarted.load().threads == [old])
    }

    @Test func legacyHeadersPreserveKnownChildrenAndNeverInventKnownRoots() throws {
        var child = try thread("child", updatedAt: 2)
        let relation = ConversationAgentRelation(parentThreadId: "parent", parentAccountId: nil, agentId: "launcher:child")
        child.agentRelation = relation
        var root = try thread("root", updatedAt: 1)
        root.agentClassification = .root
        let encoder = JSONEncoder()
        for (header, expected) in [(child, ConversationAgentClassification.child(relation)), (root, .unresolved)] {
            var legacy = try #require(JSONSerialization.jsonObject(with: encoder.encode(header)) as? [String: Any])
            legacy.removeValue(forKey: "agentClassification")
            let decoded = try JSONDecoder().decode(ConversationHeader.self, from: JSONSerialization.data(withJSONObject: legacy))
            #expect(decoded.agentClassification == expected)
            #expect(decoded.agentRelation == header.agentRelation)
        }
    }

    @Test func cachedPreviewsWithoutProvenanceAreDiscardedOnLoad() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationHeaderStore(hostID: nil, directory: directory)
        await store.save(snapshot: .init(threads: [try thread("t", updatedAt: 2)], lastSuccessfulRefreshAt: nil, revision: 1))
        let url = directory.appending(path: "default.json")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var headers = try #require(envelope["threads"] as? [[String: Any]])
        headers[0]["preview"] = """
        <remotecoder_pasted_text_v1>
        [{"id":"77777777-2222-3333-4444-555555555555","text":"Readable cached title\\nMore pasted text"}]
        </remotecoder_pasted_text_v1>
        """
        envelope["threads"] = headers
        envelope["version"] = 3
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        let reloaded = ConversationHeaderStore(hostID: nil, directory: directory)
        #expect(await reloaded.load().threads.isEmpty)
    }

    @Test(arguments: [299, 300, 3_600])
    func anUnconfirmedChatOnlyDelaysAuthoritativePruningForFiveMinutes(_ age: Int) throws {
        let now = Date(timeIntervalSince1970: 2_000)
        var pending = try thread("pending", updatedAt: 1_000)
        pending.pendingHistorySince = now.addingTimeInterval(-TimeInterval(age))
        let recent = try thread("recent", updatedAt: 500)
        let refreshed = ConversationHeaderStore.refreshing(current: [pending], recent: [recent], continuation: .init(codex: .end, claude: .end), retaining: [], now: now)
        #expect(refreshed.contains { $0.id == pending.id } == (age < 300))
    }

    @Test func recentPageRemovesContradictedDatesEvenWhenTheCorrectedThreadFallsOutsideIt() throws {
        let stale = try thread("claude_stale", updatedAt: 1_000)
        let recent = try thread("claude_recent", updatedAt: 500)
        let olderPage = try thread("claude_older", updatedAt: 50)
        let result = ConversationHeaderStore.refreshing(current: [stale, olderPage], recent: [recent], continuation: .init(codex: .end, claude: .next("older")), retaining: [])
        #expect(result.map(\.id) == [recent.id, olderPage.id])
        let corrected = try thread(stale.id, updatedAt: 25)
        #expect(ConversationHeaderStore.refreshing(current: result, recent: [recent, olderPage, corrected], continuation: .init(codex: .end, claude: .end), retaining: []).last?.updatedAt == 25)
    }

    @Test func olderChildHeadersDoNotExtendRootDeletionCoverage() throws {
        let first = try thread("rootA", updatedAt: 100)
        let cached = try thread("claude_rootB", updatedAt: 90)
        var child = try thread("childC", updatedAt: 10)
        child.agentRelation = ConversationAgentRelation(parentThreadId: first.id, parentAccountId: nil, agentId: "launcher:childC")
        let refreshed = ConversationHeaderStore.refreshing(current: [first, cached], recent: [first, child], continuation: .init(codex: .end, claude: .next("older")), retaining: [])
        #expect(Set(refreshed.map(\.id)) == ["rootA", "claude_rootB", "childC"])
        let childOnly = ConversationHeaderStore.refreshing(current: [cached], recent: [child], continuation: .init(codex: .end, claude: .notLoaded), retaining: [])
        #expect(childOnly.contains { $0.id == cached.id })
    }

    @Test func deletionCoverageIsPerProviderAndChildOnlyContinuationKeepsUnknownRoots() throws {
        let codex = try thread("codex_recent", updatedAt: 500)
        let claude = try thread("claude_recent", updatedAt: 1_000)
        let olderClaude = try thread("claude_older", updatedAt: 900)
        let contradictedClaude = try thread("claude_missing", updatedAt: 1_100)
        let merged = ConversationHeaderStore.refreshing(current: [olderClaude, contradictedClaude], recent: [codex, claude],
            continuation: .init(codex: .next("older"), claude: .next("older")), retaining: [])
        #expect(merged.contains { $0.id == olderClaude.id })
        #expect(!merged.contains { $0.id == contradictedClaude.id })
        var child = try thread("child", updatedAt: 5)
        child.agentRelation = .init(parentThreadId: "parent", parentAccountId: nil, agentId: "child")
        let parent = try thread("parent", updatedAt: 100)
        #expect(ConversationHeaderStore.refreshing(current: [parent], recent: [child],
            continuation: .init(codex: .next("older"), claude: .end), retaining: []).contains { $0.id == parent.id })
    }

    @Test func aResumedOldConversationRemainsRecentAndBoundaryTiesRemainCached() throws {
        let resumed = try thread("resumed", updatedAt: 1_000)
        let recent = try thread("z", updatedAt: 500)
        let unseenTie = try thread("a", updatedAt: 500)
        let result = ConversationHeaderStore.refreshing(current: [unseenTie, resumed], recent: [resumed, recent], continuation: .init(codex: .next("older"), claude: .end), retaining: [])
        #expect(result.map(\.id) == ["resumed", "a", "z"])
    }

    @Test func refreshPreservesNewerLocalChangesAndOlderRowsAcrossTimestampTies() throws {
        let first = try thread("a", updatedAt: 100)
        let last = try thread("z", updatedAt: 100)
        let created = try thread("local", updatedAt: 200)
        let deleted = try thread("deleted", updatedAt: 300)
        let result = ConversationHeaderStore.refreshing(
            current: [created, last], recent: [deleted, first], continuation: .init(codex: .next("older"), claude: .end), retaining: [], preserving: [created.id, deleted.id]
        )
        #expect(result.map(\.id) == [created.id, first.id, last.id])
        #expect(ConversationHeaderStore.refreshing(current: result, recent: [], continuation: .init(codex: .end, claude: .end), retaining: []).isEmpty)
    }

    @Test func serverCorrectionsReplaceInflatedActivityDates() throws {
        let stale = try thread("claude_old", updatedAt: 1_000, preview: "Old title")
        let corrected = try thread("claude_old", updatedAt: 100, preview: "Renamed")
        let recent = try thread("codex_recent", updatedAt: 500)
        let olderPage = try thread("claude_older", updatedAt: 50)
        let result = ConversationHeaderStore.merging(
            current: [stale, recent, olderPage], fetched: [corrected]
        )
        #expect(result.map(\.id) == [recent.id, corrected.id, olderPage.id])
        #expect(result[1].updatedAt == 100)
        #expect(result[1].preview == "Renamed")
    }

    @Test func equalActivityDatesHaveDeterministicOrderAndAcceptTitleChanges() throws {
        let first = try thread("a", updatedAt: 100)
        let second = try thread("b", updatedAt: 100)
        let renamed = try thread("b", updatedAt: 100, preview: "New title")
        let result = ConversationHeaderStore.merging(current: [second, first], fetched: [renamed])
        #expect(result.map(\.id) == ["a", "b"])
        #expect(result[1].preview == "New title")
        #expect(ConversationHeaderStore.merging(current: [first, second], fetched: []).map(\.id) == ["a", "b"])
    }

    @Test func obsoleteProjectionIsDiscardedAndCorrectedDatesSurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("default.json")
        var corrected = try thread("claude_old", updatedAt: 100)
        corrected.lastTurnCompletedAt = 75
        let store = ConversationHeaderStore(hostID: nil, directory: directory)
        await store.save(snapshot: .init(threads: [corrected], lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 500), revision: 2))
        let reloaded = await ConversationHeaderStore(hostID: nil, directory: directory).load()
        #expect(reloaded.threads.first?.updatedAt == 100)
        #expect(reloaded.threads.first?.lastTurnCompletedAt == 75)
        #expect(reloaded.lastSuccessfulRefreshAt == Date(timeIntervalSince1970: 500))

        for previousVersion in [1, 2, 3] {
            var oldEnvelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            oldEnvelope["version"] = previousVersion
            try JSONSerialization.data(withJSONObject: oldEnvelope).write(to: url)
            let discarded = await ConversationHeaderStore(hostID: nil, directory: directory).load()
            #expect(discarded.threads.isEmpty)
            #expect(discarded.lastSuccessfulRefreshAt == nil)
        }
    }

    @Test func unchangedHeaderFreshnessIsMemoryOnlyAndFailedWritesRetry() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let header = try thread("t", updatedAt: 2)
        let store = ConversationHeaderStore(hostID: nil, directory: directory)
        await store.save(snapshot: .init(threads: [header], lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 100), revision: 3))
        let url = directory.appending(path: "default.json")
        let before = try FileIdentity(url)
        await store.save(snapshot: .init(threads: [header], lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 200), revision: 4))
        #expect(try FileIdentity(url) == before)
        #expect(await store.load().lastSuccessfulRefreshAt == Date(timeIntervalSince1970: 200))
        #expect(await ConversationHeaderStore(hostID: nil, directory: directory).load().lastSuccessfulRefreshAt == Date(timeIntervalSince1970: 100))
        var changed = header
        changed.lastTurnCompletedAt = 150
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await store.save(snapshot: .init(threads: [changed], lastSuccessfulRefreshAt: .now, revision: 5))
        await store.flush()
        #expect(try FileIdentity(url) == before)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        await store.save(snapshot: .init(threads: [changed], lastSuccessfulRefreshAt: .now, revision: 6))
        #expect(await ConversationHeaderStore(hostID: nil, directory: directory).load().threads.first?.lastTurnCompletedAt == 150)
    }

    @Test func changedHeadersCoalesceUntilTheIntervalAndRetireFlushesTheLatest() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = HeaderWriteClock()
        let store = ConversationHeaderStore(hostID: nil, directory: directory, clock: clock)
        await store.save(snapshot: .init(threads: [try thread("t", updatedAt: 1)], lastSuccessfulRefreshAt: nil, revision: 1))
        await clock.waitUntilSleeping()
        for revision in 2...10 {
            await store.save(snapshot: .init(threads: [try thread("t", updatedAt: Int64(revision))],
                lastSuccessfulRefreshAt: nil, revision: UInt64(revision)))
        }
        #expect(await store.load().revision == 10)
        #expect(await ConversationHeaderStore(hostID: nil, directory: directory).load().revision == 1)
        clock.advance(by: .seconds(30))
        await clock.waitUntilSleeping()
        #expect(await ConversationHeaderStore(hostID: nil, directory: directory).load().revision == 10)
        await store.save(snapshot: .init(threads: [try thread("t", updatedAt: 11)], lastSuccessfulRefreshAt: nil, revision: 11))
        await store.retire()
        #expect(await ConversationHeaderStore(hostID: nil, directory: directory).load().revision == 11)
    }

    private func thread(_ id: String, updatedAt: Int64, preview: String = "Test") throws -> ConversationHeader {
        try ThreadFixture.basic(id, updatedAt: updatedAt, preview: preview)
    }

}

private final class HeaderWriteClock: Clock {
    private struct State {
        var now = ContinuousClock.now
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var observers: [CheckedContinuation<Void, Never>] = []
    }

    var now: ContinuousClock.Instant { state.withLock { $0.now } }
    let minimumResolution: Duration = .nanoseconds(1)
    private let state = Mutex(State())

    var waitingCount: Int { state.withLock { $0.waiters.count } }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        guard deadline > now else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let observers = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return []
                    }
                    state.waiters[id] = continuation
                    let observers = state.observers
                    state.observers.removeAll()
                    return observers
                }
                for observer in observers { observer.resume() }
            }
        } onCancel: {
            self.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let waiters = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilSleeping() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if !state.waiters.isEmpty { return true }
                state.observers.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
