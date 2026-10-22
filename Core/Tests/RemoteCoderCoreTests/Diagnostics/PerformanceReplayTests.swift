import Foundation
import Testing
@testable import RemoteCoderCore

@Suite struct PerformanceReplayTests {
    private func fixture(actions: [PerformanceReplayScenario.Action]? = nil) -> PerformanceReplayScenario {
        let header: JSONValue = .object(["id": .string("thread-a"), "preview": .string("Captured history"),
            "createdAt": .number(1), "updatedAt": .number(2), "cwd": .string("/replay"),
            "status": .object(["type": .string("idle")]), "source": .string("appServer")])
        let items: [JSONValue] = (0..<3).map { index in .object([
            "turnId": .string("past"), "item": .object(["type": .string("agentMessage"),
                "id": .string("item-\(index)"), "text": .string("History \(index)")]), "isComplete": .bool(true)
        ]) }
        var other = header.objectValue ?? [:]
        other["id"] = .string("claude_thread-b")
        return PerformanceReplayScenario(version: 1, capturedAt: 100, name: "contract", duration: 10,
            conversations: [.init(thread: header, items: items, turns: []), .init(thread: .object(other), items: items, turns: [])],
            events: [.init(at: 1, frame: .object(["method": .string("turn/started"),
                "params": .object(["threadId": .string("thread-a"), "turn": .object(["id": .string("live")])])]))],
            actions: actions ?? [.init(at: 0, kind: .open, threadID: "thread-a", message: nil)],
            responses: [:], errors: [:], httpResponses: [:], threadResponses: [:])
    }

    @Test func rejectsActionsOutsideTheRecordedWindow() {
        let scenario = fixture(actions: [.init(at: 11, kind: .open, threadID: "thread-a", message: nil)])
        #expect(throws: PerformanceReplayScenario.Failure.self) { try scenario.validate() }
    }

    @Test func replayKeepsRelativeAgeAfterFourDays() throws {
        let now = 100.0 + 4 * 86_400
        let shifted = try fixture().rebased(to: now)
        let wire = try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: JSONEncoder().encode(shifted.conversations[0].thread))
        let thread = ConversationHeader(wire)
        let marks = ConversationMarks(schemaVersion: 3, revision: 1, readBaseline: Int64(now), threads: [:])
        #expect(thread.updatedAt == Int64(now - 98))
        #expect(!marks.isSettled(thread, isLive: false, at: Int64(now)))
        #expect(shifted.events[0].at == 1)
    }

    @Test func cursorCanReverseDirectionWithoutDuplicatingTheAnchor() throws {
        var state = try PerformanceReplayState(fixture())
        func request(direction: String, cursor: String?) -> JSONValue {
            var params: [String: JSONValue] = ["threadId": .string("thread-a"), "limit": .number(2), "sortDirection": .string(direction)]
            if let cursor { params["cursor"] = .string(cursor) }
            return .object(["id": .number(1), "method": .string("thread/items/list"), "params": .object(params)])
        }
        let first = try #require(state.response(to: request(direction: "desc", cursor: nil))?.objectValue?["result"]?.objectValue)
        let older = try #require(state.response(to: request(direction: "desc", cursor: first["nextCursor"]?.stringValue))?.objectValue?["result"]?.objectValue)
        let oldItems = try #require(older["data"]?.arrayValue)
        #expect(oldItems.count == 1)
        #expect(oldItems.first?.objectValue?["item"]?.objectValue?["id"] == .string("item-0"))
        let newer = try #require(state.response(to: request(direction: "asc", cursor: older["backwardsCursor"]?.stringValue))?.objectValue?["result"]?.objectValue)
        let newItems = try #require(newer["data"]?.arrayValue)
        #expect(newItems.compactMap { $0.objectValue?["item"]?.objectValue?["id"]?.stringValue } == ["item-1", "item-2"])
    }

    @Test func activityPushAndReadShareRevisionsAndCompletionRecency() throws {
        var state = try PerformanceReplayState(fixture())
        let request: JSONValue = .object(["id": .number(1), "method": .string("daemon/activeTurns"), "params": .object([:])])
        let push: JSONValue = .object(["method": .string("daemon/activeTurns/changed"), "params": .object(["revision": .number(9000)])])
        state.apply(fixture().events[0].frame)
        let first = try #require(state.notification(push).objectValue?["params"])
        let firstRead = try state.response(to: request)?.objectValue?["result"]
        #expect(first == firstRead)
        state.apply(.object(["method": .string("turn/completed"), "params": .object([
            "threadId": .string("thread-a"), "turn": .object(["id": .string("live"), "completedAt": .number(109)])])]))
        let completed = try #require(state.notification(push).objectValue?["params"])
        let completedRead = try state.response(to: request)?.objectValue?["result"]
        #expect(completed == completedRead)
        #expect(completed.objectValue?["activeTurns"] == .array([]))
        let header = try #require(state.response(to: .object(["id": .number(2), "method": .string("thread/read"),
            "params": .object(["threadId": .string("thread-a")])]))?.objectValue?["result"]?.objectValue?["thread"]?.objectValue)
        #expect(header["lastTurnCompletedAt"] == .number(109))
        #expect(header["recencyAt"] == .number(109))
    }

    @Test func httpFixtureServesCapturedResponsesAndBlocksExternalRequests() async throws {
        try PerformanceReplayHTTP.install(["GET /accounts": .object(["status": .number(200),
            "body": .object(["captured": .bool(true)])])])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PerformanceReplayHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let local = try #require(URL(string: "http://127.0.0.1:1/accounts"))
        let (data, response) = try await session.data(from: local)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == .object(["captured": .bool(true)]))
        let external = try #require(URL(string: "https://example.invalid/accounts"))
        await #expect(throws: URLError.self) { try await session.data(from: external) }
        let diagnostics = PerformanceReplayHTTP.diagnostics()
        #expect(diagnostics.requests == ["GET /accounts": 1])
        #expect(diagnostics.blockedExternal == 1)
        #expect(diagnostics.missing.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func realGatewayClientReadsReplayHistoryOverLoopback() async throws {
        let server = try PerformanceReplayServer(scenario: fixture())
        let port = try await server.start()
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws"))
        let client = GatewayClient(config: .init(url: url, authToken: "fixture", hostLabel: "offline"), routes: nil)
        do {
            let page: CodexAppServerV2.ThreadItemsListResponse = try await client.callDecodable(method: "thread/items/list",
                params: .object(["threadId": .string("thread-a"), "limit": .number(2), "sortDirection": .string("desc")]), timeout: .seconds(5))
            #expect(page.data.map(\.item.id) == ["item-2", "item-1"])
            #expect(page.nextCursor == "1")
            let notification: JSONValue = .object(["method": .string("item/started"), "params": .object([
                "threadId": .string("thread-a"), "turnId": .string("live"),
                "item": .object(["type": .string("agentMessage"), "id": .string("live-item"), "text": .string("Partial")])])])
            let hiddenRecipients = try await server.deliver(notification)
            #expect(hiddenRecipients == 0)
            let refreshed: CodexAppServerV2.ThreadItemsListResponse = try await client.callDecodable(method: "thread/items/list",
                params: .object(["threadId": .string("thread-a"), "limit": .number(1), "sortDirection": .string("desc")]), timeout: .seconds(5))
            #expect(refreshed.data.first?.item.id == "live-item")
            #expect(refreshed.data.first?.isComplete == false)
            let (subscription, receipt) = try await client.subscribe(threadID: "thread-a")
            guard case .subscribed(let handle, _, let checkpoint) = subscription else {
                Issue.record("fixture observation was not subscribed")
                await server.stop()
                await client.disconnect()
                return
            }
            #expect(checkpoint.liveItems.first?.item.id == "live-item")
            #expect(checkpoint.itemsBackwardsCursor == "4")
            let visibleRecipients = try await server.deliver(notification)
            #expect(visibleRecipients == 1)
            try await client.closeSubscription(handle, connection: receipt.connection)
            let closedRecipients = try await server.deliver(notification)
            #expect(closedRecipients == 0)
            for method in ["mcpServer/startupStatus/updated", "thread/settings/updated", "thread/readState/changed"] {
                let scoped = JSONValue.object(["method": .string(method), "params": .object(["threadId": .string("thread-a")])])
                let recipients = try await server.deliver(scoped)
                #expect(recipients == 0)
            }
            let status = JSONValue.object(["method": .string("thread/status/changed"), "params": .object(["threadId": .string("thread-a")])])
            let globalRecipients = try await server.deliver(status)
            #expect(globalRecipients == 1)
            var claudeFields = try #require(notification.objectValue)
            var claudeParams = try #require(claudeFields["params"]?.objectValue)
            claudeParams["threadId"] = .string("claude_thread-b")
            claudeFields["params"] = .object(claudeParams)
            let claudeNotification = JSONValue.object(claudeFields)
            let hiddenClaude = try await server.deliver(claudeNotification)
            #expect(hiddenClaude == 0)
            _ = try await client.call(method: "conversation/subscriptions/set", params: .object([
                "threadIds": .array([.string("claude_thread-b")])]), timeout: .seconds(5))
            let visibleClaude = try await server.deliver(claudeNotification)
            #expect(visibleClaude == 1)
            _ = try await client.call(method: "conversation/subscriptions/set", params: .object([
                "threadIds": .array([])]), timeout: .seconds(5))
            let removedClaude = try await server.deliver(claudeNotification)
            #expect(removedClaude == 0)
            await server.stop()
            await client.disconnect()
            let diagnostics = await server.diagnostics()
            #expect(diagnostics.unsupported.isEmpty)
            #expect(diagnostics.failures.isEmpty)
        } catch {
            print("Replay server failure diagnostics:", await server.diagnostics())
            await server.stop()
            await client.disconnect()
            throw error
        }
    }
}
