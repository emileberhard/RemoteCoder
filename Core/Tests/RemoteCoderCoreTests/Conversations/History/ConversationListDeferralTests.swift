import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ConversationListDeferralTests {
    @Test func aStartingCodexDefersTheRefreshUntilReconnectWithoutAnError() async throws {
        try await withList { list, gateway in
            await gateway.setCodex(.failure(try Self.unavailable(.codex, "Codex is starting")))
            await gateway.setClaude(.success([.historyFixture(id: "claude_new", updatedAt: 5)]))
            await list.refresh(reason: "reconnect")

            #expect(list.errorMessage == nil)
            #expect(list.needsReconnectRefresh)
            #expect(Set(list.threads.map(\.id)) == ["cached", "claude_new"])

            await gateway.setCodex(.success([.historyFixture(id: "fresh", updatedAt: 6)]))
            await list.refreshAfterReconnect(isDrawerOpen: false)

            #expect(list.errorMessage == nil)
            #expect(!list.needsReconnectRefresh)
            #expect(list.threads.map(\.id).contains("fresh"))
        }
    }

    @Test func anUnavailableClaudeStillReportsItsFailure() async throws {
        try await withList { list, gateway in
            await gateway.setClaude(.failure(try Self.unavailable(.claude, "Claude sign-in needed")))
            await list.refresh(reason: "reconnect")

            #expect(list.errorMessage == "Claude history: Claude sign-in needed")
            #expect(list.threads.map(\.id).contains("cached"))
        }
    }

    private func withList(_ body: (ConversationList, DeferralGateway) async throws -> Void) async throws {
        let temporary = TemporaryHostStorage()
        let suiteName = "RemoteCoderCoreTests.Deferral.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { temporary.cleanUp(); defaults.removePersistentDomain(forName: suiteName) }
        let target = ExecutionTarget(hostID: UUID())
        let directory = temporary.storage.directory(for: .target(hostID: target.hostID))
        let store = ConversationHeaderStore.scoped(to: target, storage: temporary.storage)
        await store.save(snapshot: .init(threads: [.historyFixture(id: "cached", updatedAt: 1)], lastSuccessfulRefreshAt: nil, revision: 1))
        let gateway = DeferralGateway()
        let list = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: target.hostID, threadStore: store,
            marksStore: ConversationMarksStore(directory: directory), defaults: defaults)
        try await body(list, gateway)
    }

    private static func unavailable(_ provider: AgentProvider, _ reason: String) throws -> GatewayRPCFailure {
        try #require(GatewayRPCFailure(code: -32003, message: "\(provider.rawValue) is unavailable", data: .object([
            "kind": .string("providerUnavailable"), "retryable": .bool(true),
            "provider": .string(provider.rawValue), "reason": .string(reason)])))
    }
}

private actor DeferralGateway: CodexHistoryGateway, ConversationMarksRemote {
    enum Failure: Error { case unexpectedRead }
    let historyHostID = "deferral-fixture"
    private var codex: Result<[CodexAppServerV2.Thread], GatewayRPCFailure> = .success([])
    private var claude: Result<[CodexAppServerV2.Thread], GatewayRPCFailure> = .success([])

    func setCodex(_ result: Result<[CodexAppServerV2.Thread], GatewayRPCFailure>) { codex = result }
    func setClaude(_ result: Result<[CodexAppServerV2.Thread], GatewayRPCFailure>) { claude = result }

    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse {
        let threads = try codex.get()
        return .init(data: threads, nextCursor: nil, completionTimes: Dictionary(uniqueKeysWithValues: threads.map { ($0.id, Optional<Int64>.some(1)) }))
    }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse {
        .init(data: try claude.get(), nextCursor: nil)
    }
    func readThread(threadID: String, includeTurns: Bool) throws -> CodexAppServerV2.ThreadReadResponse { throw Failure.unexpectedRead }
    func historyPageData(method: String, params: JSONValue) throws -> Data {
        guard method == "conversation/agents/classify" else { throw Failure.unexpectedRead }
        let ids = params.objectValue?["threadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return try JSONSerialization.data(withJSONObject: ["result": ["relations": [:], "warnings": [], "knownRoots": ids]])
    }
    func resolveProjects(directories: [String]) -> [ProjectIdentity] { [] }
    func readConversationMarks() throws -> ConversationMarks { throw Failure.unexpectedRead }
    func updateConversationMarks(_ changes: [ConversationMarkChange]) throws -> ConversationMarks? { throw Failure.unexpectedRead }
}
