import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct QuestionReadScopeTests {
    @Test(arguments: [false, true])
    func aResponseForAnEvictedScopeCannotRepublishOrSuppressANewRead(_ retainsOwner: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let retained: ConversationSession?
        if retainsOwner { retained = await sessions.session(threadID: "evicted") }
        else { retained = nil }
        let remote = EvictedScopeQuestionRemote()
        var received: [String] = []
        let reader = QuestionReadCoordinator(remote: remote, sessions: sessions) { thread, _ in received.append(thread) }
        reader.request(threadID: "evicted")
        await remote.waitForRead(after: 0)
        for index in 0..<32 { reader.request(threadID: "other-\(index)") }
        await remote.complete()
        await remote.waitForRead(after: 1)
        #expect(!received.contains("evicted"))
        if let retained { #expect(await retained.snapshot().questionCoverage != .ready) }
        reader.changed(threadID: "evicted", epoch: "e", revision: 1, itemIDs: [])
        await remote.complete()
        await remote.waitForRead(after: 2)
        #expect(await remote.currentThreadIDs.contains("evicted"))
        let task = reader.stop()
        await remote.complete()
        await task?.value
        await sessions.invalidate(threadID: "evicted")
        #expect(await sessions.openThreadIDs().isEmpty)
    }
}

private actor EvictedScopeQuestionRemote: QuestionRemote {
    private var readCount = 0
    private var queries: [QuestionReadQuery] = []
    private var response: CheckedContinuation<[QuestionHostSnapshot], Error>?
    private var started: CheckedContinuation<Void, Never>?

    var currentThreadIDs: [String] { queries.map(\.threadId) }

    func readQuestions(_ queries: [QuestionReadQuery]) async throws -> [QuestionHostSnapshot] {
        self.queries = queries
        readCount += 1
        started?.resume()
        started = nil
        return try await withCheckedThrowingContinuation { response = $0 }
    }

    func waitForRead(after previous: Int) async {
        if readCount <= previous { await withCheckedContinuation { started = $0 } }
    }

    func complete() {
        response?.resume(returning: queries.map {
            .init(threadId: $0.threadId, epoch: "e", revision: 1, coverage: .ready, reason: nil,
                records: [], pendingItemIds: [], missingItemIds: [])
        })
        response = nil
    }

    func dismissQuestion(_ request: QuestionDismissal) async throws -> QuestionDismissalResult {
        throw CancellationError()
    }
}
