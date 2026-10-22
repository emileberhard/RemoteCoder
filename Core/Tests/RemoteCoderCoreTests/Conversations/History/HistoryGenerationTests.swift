import Foundation
import Testing
@testable import RemoteCoderCore

struct HistoryGenerationTests {
    @Test func generationRetentionStaysBoundedAndCannotReuseAnEvictedFence() {
        var generations = GatewayHistoryService.ReadGenerations()
        let initiallyMissing = generations["held"]
        generations.invalidate("held")
        let retained = generations["held"]
        for index in 0..<4_096 {
            generations.invalidate("other-\(index)")
            #expect(generations.count <= 64)
        }
        let evicted = generations["held"]
        #expect(evicted > retained)
        #expect(evicted > initiallyMissing)
        generations.invalidate("held")
        #expect(generations["held"] > evicted)
        #expect(generations.count <= 64)
        let recreated = generations["held"]
        generations.invalidate("unrelated")
        #expect(generations["held"] == recreated)
    }

    enum Invalidation: CaseIterable, Sendable {
        case thread, all, evicted
    }

    @Test(arguments: Invalidation.allCases)
    func heldReadsCannotPublishAfterInvalidation(_ invalidation: Invalidation) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryFenceGateway()
        let service = GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory, diskBudgetBytes: 0))
        let header = ConversationHeader.historyFixture(id: "held")
        await service.invalidate(threadID: header.id)
        await gateway.holdNextItems()
        let read = Task { try await service.openTail(header: header, base: nil, bypassCache: true) }
        defer { await gateway.releaseItems(); _ = await read.result }
        await gateway.waitForHeldItems()
        switch invalidation {
        case .thread: await service.invalidate(threadID: header.id)
        case .all: await service.invalidateAll()
        case .evicted:
            for index in 0..<64 { await service.invalidate(threadID: "other-\(index)") }
        }
        await gateway.releaseItems()
        switch await read.result {
        case .success: Issue.record("Invalidated history read published a snapshot")
        case .failure(let error): #expect(error as? HistoryReadFailure == .invalidated)
        }
        #expect(await service.cachedConversation(header: header) == nil)
        let fresh = try await service.openTail(header: header, base: nil, bypassCache: true)
        #expect(fresh.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "current")])
    }
}

private actor HistoryFenceGateway: CodexHistoryGateway {
    let historyHostID = "host"
    private var holdsNextItems = false
    private var heldItems: (continuation: CheckedContinuation<Data, Never>, data: Data)?
    private var itemsWaiter: CheckedContinuation<Void, Never>?

    func holdNextItems() { holdsNextItems = true }

    func waitForHeldItems() async {
        guard heldItems == nil else { return }
        await withCheckedContinuation { itemsWaiter = $0 }
    }

    func releaseItems() {
        guard let heldItems else { return }
        self.heldItems = nil
        heldItems.continuation.resume(returning: heldItems.data)
    }

    func historyPageData(method: String, params: JSONValue) async throws -> Data {
        if method == "thread/items/list" {
            let data = try JSONEncoder().encode(HistoryFenceEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(
                data: [.init(turnId: "turn", item: .agentMessage(id: "reply", text: "current"), startedAtOrdinal: 1, isComplete: true)],
                nextCursor: nil, backwardsCursor: nil)))
            guard holdsNextItems else { return data }
            holdsNextItems = false
            return await withCheckedContinuation { continuation in
                heldItems = (continuation, data)
                itemsWaiter?.resume()
                itemsWaiter = nil
            }
        }
        guard method == "thread/turns/list" else { throw GatewayClient.ClientError.invalidMessage }
        return try JSONEncoder().encode(HistoryFenceEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(
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

private nonisolated struct HistoryFenceEnvelope<Value: Encodable>: Encodable {
    let result: Value
}
