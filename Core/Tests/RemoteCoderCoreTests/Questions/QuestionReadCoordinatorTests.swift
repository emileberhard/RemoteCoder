import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct QuestionReadCoordinatorTests {
    @Test(arguments: [(Int64?.some(1_000), [Int64(1_000)]), (nil, [])])
    func questionAttentionDoesNotRequireAnUnopenedTranscriptAndRetainedQuestionsStayCurrent(
        askedAtMs: Int64?, expectedAskTimes: [Int64]
    ) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let registry = sessions(storage: temporary.storage)
        let retained = await registry.session(threadID: "retained")
        let remote = QuestionReadFixture()
        let replica = QuestionReplica(hostID: UUID(), remote: remote, sessions: registry, presentedPrompt: { _ in nil })
        replica.requestScopes(["retained", "unopened"])
        await remote.waitForRead()
        await remote.completeWithPendingQuestions(askedAtMs: askedAtMs)
        #expect(await waitUntil { replica.pendingAskTimesByThreadID == ["retained": expectedAskTimes, "unopened": expectedAskTimes] })
        #expect(await registry.openThreadIDs() == ["retained"])
        let current = await retained.snapshot()
        #expect(current.questionCoverage == .ready)
        #expect(current.questionPrompts["question"]?.isPending == true)
        await replica.invalidate()
        #expect(replica.pendingAskTimesByThreadID.isEmpty)
        #expect(await retained.snapshot().questionCoverage == .unavailable)
        #expect(await registry.openThreadIDs() == ["retained"])
        replica.stop()
        await registry.invalidate(threadID: "retained")
    }

    @Test func selectionReadsOnlyAddedScopesWhileReconnectRefreshesEveryScope() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let remote = QuestionReadFixture()
        let registry = sessions(storage: temporary.storage)
        let replica = QuestionReplica(hostID: UUID(), remote: remote, sessions: registry, presentedPrompt: { _ in nil })
        replica.requestAddedScopes(["retained"])
        await remote.waitForRead()
        await remote.completeWithPendingQuestions(askedAtMs: nil)
        #expect(await waitUntil { replica.pendingAskTimesByThreadID["retained"] != nil })
        replica.requestAddedScopes(["retained"])
        replica.requestAddedScopes(["retained", "new"])
        #expect(await waitUntil { await remote.count == 2 })
        #expect(await remote.currentThreads == ["new"])
        await remote.completeWithPendingQuestions(askedAtMs: nil)
        #expect(await waitUntil { replica.pendingAskTimesByThreadID["new"] != nil })
        replica.requestScopes(["retained", "new"])
        #expect(await waitUntil { await remote.count == 3 })
        #expect(await remote.currentThreads == ["new", "retained"])
        let stopped = replica.stop()
        await remote.completeWithPendingQuestions(askedAtMs: nil)
        await stopped?.value
    }

    @Test(arguments: [false, true])
    func bindingASessionLoadsItsQuestionsWithoutRefreshingOtherScopes(attentionReadFinished: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let remote = QuestionReadFixture()
        let registry = sessions(storage: temporary.storage)
        let replica = QuestionReplica(hostID: UUID(), remote: remote, sessions: registry, presentedPrompt: { _ in nil })
        replica.requestAddedScopes(["selected", "other"])
        await remote.waitForRead()
        if attentionReadFinished {
            await remote.completeWithPendingQuestions(askedAtMs: 1_000)
            #expect(await waitUntil { replica.pendingAskTimesByThreadID.count == 2 })
        }
        #expect(await registry.openThreadIDs().isEmpty)

        let session = await registry.session(threadID: "selected")
        let initial = await session.snapshot()
        #expect(initial.questionCoverage == .unavailable)
        replica.requestAddedScopes(["selected", "other"])
        replica.sessionBound(initial)
        if attentionReadFinished {
            #expect(await waitUntil { await remote.count == 2 })
            #expect(await remote.currentThreads == ["selected"])
        }
        await remote.completeWithPendingQuestions(askedAtMs: 1_000)
        #expect(await waitUntil { await session.snapshot().questionCoverage == .ready })
        let current = await session.snapshot()
        #expect(current.questionPrompts["question"]?.isPending == true)
        #expect(current.questionPrompts["question"]?.record?.askedAtMs == 1_000)

        replica.sessionBound(current)
        replica.requestAddedScopes(["selected", "other", "new"])
        #expect(await waitUntil { await remote.count == (attentionReadFinished ? 3 : 2) })
        #expect(await remote.currentThreads == ["new"])
        await remote.completeWithPendingQuestions(askedAtMs: 1_000)
        #expect(await waitUntil { replica.pendingAskTimesByThreadID["new"] == [1_000] })
        let stopped = replica.stop()
        await remote.completeWithPendingQuestions(askedAtMs: 1_000)
        await stopped?.value
        #expect(await remote.count == (attentionReadFinished ? 3 : 2))
        #expect(await registry.openThreadIDs() == ["selected"])
        await registry.invalidate(threadID: "selected")
    }

    @Test func anInvalidationForTheReturnedRevisionDoesNotCreateAReadLoop() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let remote = QuestionReadFixture()
        var received: [(String, [Int64]?)] = []
        let registry = sessions(storage: temporary.storage)
        let reader = QuestionReadCoordinator(remote: remote, sessions: registry) { received.append(($0, $1)) }
        reader.request(threadID: "thread")
        await remote.waitForRead()
        for _ in 0..<20 { reader.changed(threadID: "thread", epoch: "e", revision: 1, itemIDs: []) }
        await remote.complete()
        #expect(await waitUntil { received.count == 1 })
        for _ in 0..<20 { reader.changed(threadID: "thread", epoch: "e", revision: 1, itemIDs: []) }
        let deadline = ContinuousClock.now + .milliseconds(200)
        while ContinuousClock.now < deadline, await remote.count == 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await remote.count == 1)
        #expect(received[0].0 == "thread")
        #expect(received[0].1 == [])
        #expect(await registry.openThreadIDs().isEmpty)
        await reader.invalidate()
        #expect(received.last?.1 == nil)
        #expect(await registry.openThreadIDs().isEmpty)
        reader.stop()
    }

    @Test func selectingARetainedSessionRetriesItsFailedQuestionRead() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let registry = sessions(storage: temporary.storage)
        let session = await registry.session(threadID: "retained")
        _ = try await session.mergeQuestions(.init(threadId: "retained", epoch: "e", revision: 0,
            coverage: .ready, reason: nil, records: [], pendingItemIds: [], missingItemIds: []))
        let remote = QuestionReadFixture()
        let replica = QuestionReplica(hostID: UUID(), remote: remote, sessions: registry, presentedPrompt: { _ in nil })
        replica.requestAddedScopes(["retained"])
        await remote.waitForRead()
        await remote.fail()
        #expect(await waitUntil { await session.snapshot().questionCoverage == .unavailable })
        replica.requestAddedScopes(["retained"])
        replica.sessionBound(await session.snapshot())
        #expect(await waitUntil { await remote.count == 2 })
        #expect(await remote.currentThreads == ["retained"])
        await remote.completeWithPendingQuestions(askedAtMs: 1_000)
        #expect(await waitUntil { await session.snapshot().questionCoverage == .ready })
        #expect(await session.snapshot().questionPrompts["question"]?.isPending == true)
        let stopped = replica.stop()
        await remote.completeWithPendingQuestions(askedAtMs: 1_000)
        await stopped?.value
        await registry.invalidate(threadID: "retained")
    }

    @Test func stoppedOwnerRejectsALateResponse() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let remote = QuestionReadFixture()
        var received = 0
        let reader = QuestionReadCoordinator(remote: remote, sessions: sessions(storage: temporary.storage)) { _, _ in received += 1 }
        reader.request(threadID: "thread")
        await remote.waitForRead()
        let task = reader.stop()
        await remote.complete()
        await task?.value
        #expect(received == 0)
        reader.request(threadID: "other")
        #expect(await remote.count == 1)
    }

    private func sessions(storage: HostStorage) -> ConversationSessions {
        let hostID = UUID()
        return ConversationSessions(hostID: hostID, sessionIndex: ConversationIndex(hostID: hostID, storage: storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: storage)
    }
}

private actor QuestionReadFixture: QuestionRemote {
    private(set) var count = 0
    private var queries: [QuestionReadQuery] = []
    var currentThreads: [String] { queries.map(\.threadId).sorted() }
    private var continuation: CheckedContinuation<[QuestionHostSnapshot], Error>?
    private var started: CheckedContinuation<Void, Never>?
    func readQuestions(_ queries: [QuestionReadQuery]) async throws -> [QuestionHostSnapshot] {
        count += 1
        self.queries = queries
        started?.resume(); started = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func dismissQuestion(_ request: QuestionDismissal) async throws -> QuestionDismissalResult {
        throw CancellationError()
    }
    func waitForRead() async {
        if count == 0 { await withCheckedContinuation { started = $0 } }
    }
    func complete() {
        continuation?.resume(returning: [.init(threadId: "thread", epoch: "e", revision: 1,
            coverage: .ready, reason: nil, records: [], pendingItemIds: [], missingItemIds: [])])
        continuation = nil
    }

    func fail() {
        continuation?.resume(throwing: GatewayClient.ClientError.connectionClosed)
        continuation = nil
    }

    func completeWithPendingQuestions(askedAtMs: Int64?) {
        continuation?.resume(returning: queries.map { query in
            .init(threadId: query.threadId, epoch: "e", revision: 1, coverage: .ready, reason: nil,
                records: [.init(itemId: "question", turnId: "turn", ordinal: 1, askedAtMs: askedAtMs, revision: 1,
                    questions: [.init(index: 0, title: "Continue?", options: [], resolution: .pending, answer: nil)])],
                pendingItemIds: ["question"], missingItemIds: [])
        })
        continuation = nil
    }
}
