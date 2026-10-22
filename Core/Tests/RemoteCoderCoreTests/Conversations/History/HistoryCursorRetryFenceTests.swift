import Foundation
import Testing
@testable import RemoteCoderCore

struct HistoryCursorRetryFenceTests {
    @Test(.timeLimit(.minutes(1))) func invalidationAfterACursorFailureCannotPublishTheResetTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = try #require(GatewayRPCFailure(code: -32000, message: "Cursor expired", data: .object([
            "kind": .string("historyCursorInvalid"), "retryable": .bool(true)])))
        let executor = ManualTaskExecutor()
        let gateway = CursorRetryFenceGateway(failure: failure)
        let service = GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory, diskBudgetBytes: 0))
        var window = HistoryWindow()
        window.apply(.init(items: .init(elements: [], older: "expired", newer: nil, fetchedAt: .now), placement: .tail, metadata: []))
        let base = window
        let target = Task(executorPreference: executor, priority: .background) { try await service.page(header: .historyFixture(id: "target"), window: base, direction: .desc, priority: .foreground) }
        let filler = Task { try await service.page(header: .historyFixture(id: "filler"), window: base, direction: .desc, priority: .foreground) }
        defer {
            executor.resume()
            target.cancel()
            filler.cancel()
            await gateway.releaseAllPages()
            _ = await target.result
            _ = await filler.result
        }
        await gateway.waitForPage("target")
        await gateway.waitForPage("filler")
        let probe = Task { try await service.page(header: .historyFixture(id: "probe"), window: base, direction: .desc, priority: .foreground) }
        defer { probe.cancel(); await gateway.releaseAllPages(); _ = await probe.result }
        try await eventually { await service.diagnosticCounters().pendingReads == 3 }

        executor.pause()
        await gateway.failPage("target")
        try await executor.waitForJob()
        await gateway.waitForPage("probe")
        let invalidation = Task(priority: .high) { await service.invalidate(threadID: "target") }
        await invalidation.value
        executor.resume()
        filler.cancel()
        probe.cancel()
        await gateway.releaseAllPages()
        _ = await filler.result
        _ = await probe.result

        switch await target.result {
        case .success: Issue.record("Invalidated page read published its reset tail")
        case .failure(let error): #expect(error as? HistoryReadFailure == .invalidated)
        }
        await gateway.stopHoldingPages()
        let fresh = try await service.page(header: .historyFixture(id: "target"), window: base, direction: .desc, priority: .foreground)
        #expect(fresh.window.turns.flatMap { $0.entries.map(\.item) } == [.agentMessage(id: "reply", text: "fresh")])
    }
}

private actor CursorRetryFenceGateway: CodexHistoryGateway {
    private let failure: GatewayRPCFailure
    private var holdsPages = true
    private var pages: [String: CheckedContinuation<Data, any Error>] = [:]
    private var pageWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    init(failure: GatewayRPCFailure) { self.failure = failure }

    var historyHostID: String { "host" }

    func stopHoldingPages() { holdsPages = false }

    func waitForPage(_ threadID: String) async {
        guard pages[threadID] == nil else { return }
        await withCheckedContinuation { pageWaiters[threadID] = $0 }
    }

    func failPage(_ threadID: String) { pages.removeValue(forKey: threadID)?.resume(throwing: failure) }

    func releaseAllPages() {
        for continuation in pages.values { continuation.resume(throwing: CancellationError()) }
        pages.removeAll()
    }

    func historyPageData(method: String, params: JSONValue) async throws -> Data {
        if method == "thread/items/list", params.objectValue?["cursor"] != nil {
            guard holdsPages else { throw failure }
            guard let threadID = params.objectValue?["threadId"]?.stringValue else { throw GatewayClient.ClientError.invalidMessage }
            return try await withCheckedThrowingContinuation { continuation in
                pages[threadID] = continuation
                pageWaiters.removeValue(forKey: threadID)?.resume()
            }
        }
        if method == "thread/items/list" {
            return try JSONEncoder().encode(CursorRetryEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(
                data: [.init(turnId: "turn", item: .agentMessage(id: "reply", text: "fresh"), startedAtOrdinal: 1, isComplete: true)],
                nextCursor: nil, backwardsCursor: nil)))
        }
        guard method == "thread/turns/list" else { throw GatewayClient.ClientError.invalidMessage }
        return try JSONEncoder().encode(CursorRetryEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(
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

private nonisolated struct CursorRetryEnvelope<Value: Encodable>: Encodable {
    let result: Value
}
