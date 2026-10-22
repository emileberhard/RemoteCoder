import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ConversationListProjectTests {
    enum AdmissionChange: Equatable, Sendable { case eviction, readmission, unchanged }

    @Test(.timeLimit(.minutes(1)), arguments: [AdmissionChange.eviction, .readmission, .unchanged])
    func heldProjectReadCannotReplaceMoreRecentCacheState(_ change: AdmissionChange) async throws {
        let temporary = TemporaryHostStorage()
        let gateway = ProjectReadGateway()
        let suiteName = "RemoteCoderCoreTests.Projects.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { await gateway.release(); temporary.cleanUp(); defaults.removePersistentDomain(forName: suiteName) }
        let target = ExecutionTarget(hostID: UUID())
        let directory = temporary.storage.directory(for: .target(hostID: target.hostID))
        let store = ConversationHeaderStore.scoped(to: target, storage: temporary.storage)
        let old = try ThreadFixture.basic("old", updatedAt: 1, fields: ["cwd": "/old"])
        await store.save(snapshot: .init(threads: [old], lastSuccessfulRefreshAt: nil, revision: 1))
        let list = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: target.hostID, threadStore: store,
            marksStore: ConversationMarksStore(directory: directory), defaults: defaults)
        _ = await list.knownThread(id: old.id)
        await gateway.hold()
        let loading = Task { await list.resolveProjects() }
        await gateway.waitForRead()
        await gateway.setName("Current project")
        let replacement = try ThreadFixture.basic("new", updatedAt: 2, fields: ["cwd": "/new"])
        if change != .unchanged {
            await list.record(replacement)
            await list.forget(old.id)
            #expect(list.header(id: old.id) == nil)
        }
        if change != .eviction {
            if change == .readmission {
                await list.forget(replacement.id)
                await list.record(old)
            }
            await list.resolveProjects()
            #expect(list.projects[old.cwd]?.name == "Current project")
        }
        await gateway.release()
        await loading.value
        if change != .eviction { #expect(list.projects[old.cwd]?.name == "Current project") }
        else {
            #expect(list.projects[old.cwd] == nil)
            await list.resolveProjects()
            #expect(list.projects[replacement.cwd]?.name == "Current project")
        }
        let admittedDirectories = Set(list.threads.map(\.cwd))
        #expect(Set(list.projects.keys).isSubset(of: admittedDirectories))
    }
}

actor ProjectReadGateway: CodexHistoryGateway, ConversationMarksRemote {
    enum Failure: Error { case unexpectedRead }
    let historyHostID = "project-read-fixture"
    private var name = "Previous project"
    private var held = false
    private var suspension: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func hold() { held = true }
    func setName(_ name: String) { self.name = name }
    func waitForRead() async {
        if suspension == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func release() { suspension?.resume(); suspension = nil }
    func resolveProjects(directories: [String]) async -> [ProjectIdentity] {
        let captured = directories.map { ProjectIdentity(cwd: $0, kind: .directory, key: $0, name: name, root: $0) }
        if held {
            held = false
            await withCheckedContinuation { suspension = $0; arrival?.resume(); arrival = nil }
        }
        return captured
    }
    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse { throw Failure.unexpectedRead }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw Failure.unexpectedRead }
    func readThread(threadID: String, includeTurns: Bool) throws -> CodexAppServerV2.ThreadReadResponse { throw Failure.unexpectedRead }
    func historyPageData(method: String, params: JSONValue) throws -> Data { throw Failure.unexpectedRead }
    func readConversationMarks() throws -> ConversationMarks { throw Failure.unexpectedRead }
    func updateConversationMarks(_ changes: [ConversationMarkChange]) throws -> ConversationMarks? { throw Failure.unexpectedRead }
}
