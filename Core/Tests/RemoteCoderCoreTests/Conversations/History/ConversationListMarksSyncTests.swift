import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ConversationListMarksSyncTests {
    @Test(.timeLimit(.minutes(1))) func aFailedReadRetriesOnItsOwnUntilTheMarksArrive() async throws {
        let gateway = FlakyMarksGateway()
        try await withList(gateway, stored: nil) { list in
            await list.syncMarks()
            #expect(list.marksNeedSync)
            #expect(list.marks.settlement(of: "done") == nil)

            await gateway.setAvailable(true)
            try await waitUntil { !list.marksNeedSync }
            #expect(list.marks.settlement(of: "done") == .settled(through: 100))
        }
    }

    @Test(.timeLimit(.minutes(1))) func aFailedWriteAfterAGoodSyncRetriesWithoutAnotherCommand() async throws {
        let gateway = FlakyMarksGateway()
        await gateway.setAvailable(true)
        try await withList(gateway, stored: nil) { list in
            await list.syncMarks()
            #expect(!list.marksNeedSync)

            await gateway.setAvailable(false)
            list.pin(threadID: "done", name: "Keep")
            try await waitUntil { await gateway.failedWrites > 0 }
            #expect(list.marksNeedSync)

            await gateway.setAvailable(true)
            try await waitUntil { !list.marksNeedSync }
            #expect(await gateway.updates == [[.pin(threadID: "done", name: "Keep")]])
        }
    }

    @Test(.timeLimit(.minutes(1))) func aSuspendedSyncSendsNothingUntilTheNextConnection() async throws {
        let gateway = FlakyMarksGateway()
        await gateway.setAvailable(true)
        try await withList(gateway, stored: nil) { list in
            await list.syncMarks()
            await gateway.setAvailable(false)
            list.pin(threadID: "done", name: "Keep")
            try await waitUntil { await gateway.failedWrites == 1 }

            await gateway.holdReads()
            let reconnect = Task { await list.syncMarks() }
            try await waitUntil { await gateway.isHoldingRead }
            list.suspendMarksSync()
            await gateway.releaseRead()
            await reconnect.value
            await gateway.setAvailable(true)
            try await Task.sleep(for: .seconds(3))
            #expect(await gateway.failedWrites == 1)
            #expect(await gateway.updates.isEmpty)

            await list.syncMarks()
            #expect(await gateway.updates == [[.pin(threadID: "done", name: "Keep")]])
        }
    }

    @Test(arguments: [false, true])
    func retirementWaitsForAFullCapableReadAndKeepsAnUnsupportedScopePending(hasScopedRead: Bool) async throws {
        let gateway = FlakyMarksGateway()
        var replica = ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 9, readBaseline: 300,
            threads: ["done": ThreadMarks(pinName: "Cached pin")]))
        replica.record(.markRead(threadID: "source-only", through: 250))
        if hasScopedRead { replica.record(.markAllRead(through: 350)) }
        var expected = replica
        expected.retireDefaultScope()
        try await withList(gateway, stored: replica) { list in
            await list.syncMarks()
            #expect(!list.marksReplica.isReadStateKnown)
            #expect(list.marks.pinName(for: "done") == "Cached pin")
            #expect(await gateway.failedWrites == 0)
            #expect(list.marksReplica.pending == expected.pending)
            await gateway.setAvailable(true)
            await list.syncMarks()
            #expect(!list.marksReplica.isReadStateKnown)
            #expect(await gateway.failedWrites == 0)
            #expect(list.marksReplica.pending == expected.pending)
            await gateway.setRetirementReadAvailable()
            await list.syncMarks()
            #expect(list.marksReplica.isReadStateKnown)
            #expect(list.marksReplica.acknowledged?.readBaseline == 0)
            if hasScopedRead {
                #expect(await gateway.failedWrites > 0)
                #expect(list.marksReplica.pending == expected.pending)
                await gateway.setRetirementScopesAvailable()
                await list.syncMarks()
            }
            #expect(list.marksReplica.pending.isEmpty)
            #expect(await gateway.updates == [expected.pending.map(\.change)])
        }
    }

    @Test func aNewHostsQueuedGlobalActionStaysGlobalDuringItsFirstMarksLoad() async throws {
        let gateway = FlakyMarksGateway()
        await gateway.setAvailable(true)
        try await withList(gateway, stored: nil) { list in
            list.markAllRead()
            let pending = list.marksReplica.pending
            try #require(pending.count == 1)
            guard case .markAllRead = pending[0].change else {
                Issue.record("A new host action must remain global")
                return
            }
            await list.syncMarks()
            #expect(list.marksReplica.isReadStateKnown)
            #expect(await gateway.updates == [pending.map(\.change)])
            var restored = try JSONDecoder().decode(ConversationMarksReplica.self, from: JSONEncoder().encode(list.marksReplica))
            restored.record(.markAllRead(through: 400))
            restored.retireDefaultScope()
            #expect(restored.pending.last?.change == .markAllRead(through: 400))
        }
    }

    private func withList(_ gateway: FlakyMarksGateway, stored: ConversationMarksReplica?, _ body: (ConversationList) async throws -> Void) async throws {
        let temporary = TemporaryHostStorage()
        let suiteName = "RemoteCoderCoreTests.MarksSync.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { temporary.cleanUp(); defaults.removePersistentDomain(forName: suiteName) }
        let target = ExecutionTarget(hostID: UUID())
        let directory = temporary.storage.directory(for: .target(hostID: target.hostID))
        if let stored { try #require(await ConversationMarksStore(directory: directory).save(stored)) }
        let list = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: target.hostID, threadStore: ConversationHeaderStore.scoped(to: target, storage: temporary.storage),
            marksStore: ConversationMarksStore(directory: directory), defaults: defaults)
        try await body(list)
        list.quiesce()
        await list.drain()
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        while !(await condition()) { try await Task.sleep(for: .milliseconds(50)) }
    }
}

actor FlakyMarksGateway: CodexHistoryGateway, ConversationMarksRemote {
    enum Failure: Error { case unavailable, unexpectedCall }
    let historyHostID = "flaky-marks-fixture"
    private var isAvailable = false
    private var retirementScopesAvailable = false
    private var retirementReadAvailable = false
    private var holdsReads = false
    private var heldRead: CheckedContinuation<Void, Never>?
    private(set) var failedWrites = 0
    private(set) var updates: [[ConversationMarkChange]] = []

    func setRetirementReadAvailable() { retirementReadAvailable = true }
    func setRetirementScopesAvailable() { retirementScopesAvailable = true }
    func setAvailable(_ available: Bool) { isAvailable = available }
    func holdReads() { holdsReads = true }
    var isHoldingRead: Bool { heldRead != nil }
    func releaseRead() {
        holdsReads = false
        heldRead?.resume()
        heldRead = nil
    }
    func readConversationMarks() async throws -> ConversationMarks {
        if holdsReads { await withCheckedContinuation { heldRead = $0 } }
        guard isAvailable else { throw Failure.unavailable }
        let capability = retirementReadAvailable ? #", "supportsRetiredScopeRead": true"# : ""
        return try JSONDecoder().decode(ConversationMarks.self, from: Data("""
            {"schemaVersion":2,"revision":1,"readBaseline":0,
             "threads":{"done":{"revision":1,"settlement":{"state":"settled","through":100}}}\(capability)}
            """.utf8))
    }
    func updateConversationMarks(_ changes: [ConversationMarkChange]) throws -> ConversationMarks? {
        guard isAvailable else { failedWrites += 1; throw Failure.unavailable }
        if !retirementScopesAvailable, changes.contains(where: { if case .markRetiredScopeRead = $0 { true } else { false } }) {
            failedWrites += 1
            throw Failure.unavailable
        }
        updates.append(changes)
        return nil
    }
    func resolveProjects(directories: [String]) throws -> [ProjectIdentity] { throw Failure.unexpectedCall }
    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse { throw Failure.unexpectedCall }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw Failure.unexpectedCall }
    func readThread(threadID: String, includeTurns: Bool) throws -> CodexAppServerV2.ThreadReadResponse { throw Failure.unexpectedCall }
    func historyPageData(method: String, params: JSONValue) throws -> Data { throw Failure.unexpectedCall }
}
