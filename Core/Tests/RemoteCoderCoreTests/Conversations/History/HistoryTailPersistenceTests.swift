import Foundation
import Testing
@testable import RemoteCoderCore

struct HistoryTailPersistenceTests {
    @Test func oversizedRunningTailPreservesTheLastSettledDiskCopy() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory, memoryBudgetBytes: 6)
        let key = HistoryPageKey(hostID: "host", provider: "codex", threadID: "thread", generation: 0, request: "tail")
        try await cache.store(Data([1, 2, 3]), for: key, startedAt: .now, readStartedAt: .now)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        let settled = try FileIdentity(file)
        try await cache.store(Data(repeating: 9, count: 7), for: key, startedAt: .now, readStartedAt: .now, persistence: .memoryOverDisk)
        #expect(try FileIdentity(file) == settled)
        let restored = HistoryPageCache(directory: directory, memoryBudgetBytes: 6)
        #expect(await restored.value(for: key)?.data == Data([1, 2, 3]))
    }

    @Test func runningTailStaysInMemoryAndCompletionBecomesDurable() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = GrowingTurnGateway()
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let header = ConversationHeader.historyFixture(id: "growing-turn")
        let settled = try await service.openTail(header: header, base: nil, bypassCache: true)

        await gateway.startTurn()
        var window = settled.window
        for _ in 0..<3 {
            await gateway.grow()
            window = try await service.openTail(header: header, base: window, bypassCache: true).window
        }
        let warm = try #require(await service.cachedConversation(header: header))
        #expect(warm.window.turns.last?.entries.last?.item == window.turns.last?.entries.last?.item)
        let relaunched = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let lastSettled = try #require(await relaunched.cachedConversation(header: header))
        #expect(lastSettled.window.turns.flatMap { $0.entries.map(\.item) } == settled.window.turns.flatMap { $0.entries.map(\.item) })

        await gateway.completeTurn()
        window = try await service.openTail(header: header, base: window, bypassCache: true).window
        let cold = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let restored = try #require(await cold.cachedConversation(header: header))
        #expect(restored.window.turns.flatMap { $0.entries.map(\.item) } == window.turns.flatMap { $0.entries.map(\.item) })
    }

}

private actor GrowingTurnGateway: CodexHistoryGateway {
    typealias Entry = CodexAppServerV2.ThreadItemsListResponse.Entry
    let historyHostID = "growing-turn-host"
    private var runningText: String?
    private var runningStatus: CodexAppServerV2.TurnStatus?

    func startTurn() {
        runningText = ""
        runningStatus = .inProgress
    }

    func grow() {
        runningText? += String(repeating: "streamed ", count: 2)
    }

    func completeTurn() {
        runningStatus = .completed
    }

    func historyPageData(method: String, params: JSONValue) throws -> Data {
        if method == "thread/items/list" {
            var entries = (0..<2).map { (index: Int64) in
                Entry(turnId: "settled", item: .agentMessage(id: "reply-\(index)", text: String(repeating: "abcdefghij", count: 4)),
                    startedAtOrdinal: index, isComplete: true)
            }
            if let runningText, let runningStatus {
                entries.append(Entry(turnId: "running", item: .agentMessage(id: "streaming", text: runningText),
                    startedAtOrdinal: 2, isComplete: runningStatus == .completed))
            }
            return try JSONEncoder().encode(GrowingTurnEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(
                data: entries.reversed(), nextCursor: "older-opaque", backwardsCursor: nil)))
        }
        var turns: [CodexAppServerV2.Turn] = [.init(id: "settled", items: [], startedAt: 1, completedAt: 2, status: .completed, error: nil)]
        if let runningStatus {
            turns.insert(.init(id: "running", items: [], startedAt: 3, completedAt: runningStatus == .completed ? 4 : nil,
                status: runningStatus, error: nil), at: 0)
        }
        return try JSONEncoder().encode(GrowingTurnEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(
            data: turns, nextCursor: nil, backwardsCursor: nil)))
    }

    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse { throw GatewayClient.ClientError.invalidMessage }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw GatewayClient.ClientError.invalidMessage }
    func readThread(threadID: String, includeTurns: Bool) -> CodexAppServerV2.ThreadReadResponse { .init(thread: .historyFixture(id: threadID)) }
}

private nonisolated struct GrowingTurnEnvelope<T: Encodable>: Encodable { let result: T }
