import Foundation
import Synchronization
import Testing
@testable import RemoteCoderCore

struct HistoryCheckpointFenceTests {
    @Test func invalidationBetweenPagesCannotPublishAMixedCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HistoryPageCache(directory: directory, diskBudgetBytes: 0)
        let executor = ManualTaskExecutor()
        let firstDecoded = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let firstPage = Mutex(true)
        let gateway = CheckpointFenceGateway()
        let service = GatewayHistoryService(gateway: gateway, cache: cache, now: {
            if firstPage.withLock({ first in let shouldPause = first; first = false; return shouldPause }) {
                executor.pause()
                firstDecoded.continuation.yield()
                firstDecoded.continuation.finish()
            }
            return Date(timeIntervalSince1970: 1_000)
        })
        let header = ConversationHeader.historyFixture(id: "checkpoint")
        let checkpoint = CodexAppServerV2.ThreadObservationCheckpoint(turnsBackwardsCursor: nil,
            itemsBackwardsCursor: "first", activeTurn: nil, historyUnavailable: false, liveItems: [])
        let read = Task(executorPreference: executor, priority: .background) { try await service.observationCheckpoint(header: header, checkpoint: checkpoint, previous: nil) }
        defer { executor.resume(); _ = await read.result }
        var fetchedPages = firstDecoded.stream.makeAsyncIterator()
        try #require(await fetchedPages.next() != nil)
        try await executor.waitForJob()
        try await executor.runNext()
        try await executor.waitForJob()
        let firstKey = HistoryPageKey(hostID: "host", provider: "native", threadID: header.id,
            generation: UInt64(bitPattern: header.updatedAt),
            request: "native-v4:thread/items/list{\"cursor\":\"first\",\"limit\":50,\"sortDirection\":\"desc\",\"threadId\":\"checkpoint\"}")
        let storedFirstPage = Task(priority: .high) { await cache.value(for: firstKey, now: Date(timeIntervalSince1970: 1_000)) }
        try #require(await storedFirstPage.value != nil)
        let invalidation = Task(priority: .high) { await service.invalidate(threadID: header.id) }
        await invalidation.value
        await gateway.revise()
        executor.resume()

        switch await read.result {
        case .success:
            Issue.record("Invalidated checkpoint read published a snapshot")
        case .failure(let error): #expect(error as? HistoryReadFailure == .invalidated)
        }
        let fresh = try await service.observationCheckpoint(header: header, checkpoint: checkpoint, previous: nil)
        #expect(fresh.entries.map(\.item) == [
            .agentMessage(id: "second", text: "new:second"), .agentMessage(id: "first", text: "new:first")])
    }
}

private actor CheckpointFenceGateway: CodexHistoryGateway {
    private var revised = false
    var historyHostID: String { "host" }
    func revise() { revised = true }

    func historyPageData(method: String, params: JSONValue) throws -> Data {
        guard method == "thread/items/list", let cursor = params.objectValue?["cursor"]?.stringValue else {
            throw GatewayClient.ClientError.invalidMessage
        }
        let first = cursor == "first"
        return try JSONEncoder().encode(CheckpointFenceEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(
            data: [.init(turnId: "turn", item: .agentMessage(id: cursor, text: "\(revised ? "new" : "old"):\(cursor)"),
                startedAtOrdinal: first ? 2 : 1, isComplete: true)],
            nextCursor: first ? "second" : nil, backwardsCursor: nil)))
    }

    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse {
        throw GatewayClient.ClientError.invalidMessage
    }

    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw GatewayClient.ClientError.invalidMessage }

    func readThread(threadID: String, includeTurns: Bool) -> CodexAppServerV2.ThreadReadResponse {
        .init(thread: .historyFixture(id: threadID))
    }
}

private nonisolated struct CheckpointFenceEnvelope<Value: Encodable>: Encodable {
    let result: Value
}
