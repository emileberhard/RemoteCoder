import Foundation
import Testing
@testable import RemoteCoderCore

@Suite(.timeLimit(.minutes(1)))
struct ContentSubscriptionRejectionTests {
    @Test(arguments: [-32600, -32601, -32001, -32602])
    func rejectedInitialSetStillInitializesReadsAndNeverReconnects(code: Int64) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await fixture.start()
        await fixture.rejectContentSubscriptions(code: code)
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        do {
            await gateway.replaceContentSubscriptions(threadIDs: ["claude_b"], revision: 1)
            try await gateway.connectIfNeeded()
            #expect(await gateway.isConnected)
            let connection = try #require(await gateway.connectionIdentity)
            for _ in 0..<3 {
                try await gateway.connectIfNeeded()
                let read = try await gateway.readThread(threadID: "claude_b", includeTurns: false)
                #expect(read.thread.id == "claude_b")
                try await assertRecoveredHistory(gateway)
                #expect(await gateway.connectionIdentity == connection)
            }
            await assertRejectedState(gateway, code: code)
            await gateway.replaceContentSubscriptions(threadIDs: ["claude_b"], revision: 2)
            try await gateway.connectIfNeeded()
            #expect(await gateway.connectionIdentity == connection)
            #expect(await fixture.acceptedConnections == 1)
            #expect(await fixture.recordedRequests.filter { $0.method == "initialize" }.count == 1)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/subscriptions/set" }.count == 1)
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }

    @Test(arguments: [-32001, -32602])
    func rejectedReplacementKeepsOldSetAndNewThreadLoadsFromReads(code: Int64) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        do {
            await gateway.replaceContentSubscriptions(threadIDs: ["claude_a"], revision: 1)
            try await gateway.connectIfNeeded()
            let connection = try #require(await gateway.connectionIdentity)
            #expect(await fixture.acknowledgedContentSubscriptions == ["claude_a"])
            guard case .subscribed(let threads) = await gateway.contentSubscriptionState else {
                Issue.record("The first set must be acknowledged")
                await gateway.retire()
                await fixture.stop()
                return
            }
            #expect(threads == ["claude_a"])
            await fixture.rejectContentSubscriptions(code: code)
            await fixture.setHistoryResult(.object(["data": .array([.object(["turnId": .string("turn-b"),
                "item": .object(["id": .string("answer-b"), "type": .string("agentMessage"), "text": .string("Recovered")]),
                "isComplete": .bool(false)])]), "nextCursor": .null, "backwardsCursor": .null]))
            await gateway.replaceContentSubscriptions(threadIDs: ["claude_b"], revision: 2)
            let header = try await gateway.readThread(threadID: "claude_b", includeTurns: false)
            #expect(header.thread.id == "claude_b")
            await assertRejectedState(gateway, code: code)
            struct Response: Decodable { let result: CodexAppServerV2.ThreadItemsListResponse }
            let bytes = try await gateway.historyPageData(method: "thread/items/list",
                params: .object(["threadId": .string("claude_b"), "limit": .number(10)]))
            let page = try JSONDecoder().decode(Response.self, from: bytes).result
            var state = ConversationState(conversationID: UUID(), threadID: "claude_b")
            state.merge(.fixture(threadID: "claude_b", wire: page.data, turns: [.init(id: "turn-b", items: [],
                startedAt: 1, completedAt: nil, status: .inProgress, error: nil)]))
            state.apply(try GatewayEventFixture.delta(" suffix", threadID: "claude_b", turnID: "turn-b", itemID: "answer-b"))
            #expect(state.turns["turn-b"]?.items["answer-b"]?.value == .agentMessage(id: "answer-b", text: "Recovered"))
            #expect(state.turns["turn-b"]?.items["answer-b"]?.completed == false)
            let replay = try await gateway.replayThreadNotifications(afterSequence: 0, epoch: nil, threadID: "claude_b")
            #expect(replay.notifications.map(\.message) == [DeviceToolSocketFixture.completedMessage])
            let message = try #require(replay.notifications.first?.message.objectValue)
            let params = try #require(message["params"]?.objectValue)
            state.apply(try GatewayEventFixture.turn("item/completed", params: params), replay: true)
            #expect(state.turns["turn-b"]?.items["answer-b"]?.value == .agentMessage(id: "answer-b", text: "Recovered answer"))
            #expect(state.turns["turn-b"]?.items["answer-b"]?.completed == true)
            try await gateway.connectIfNeeded()
            #expect(await fixture.acknowledgedContentSubscriptions == ["claude_a"])
            #expect(await fixture.acceptedConnections == 1)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/subscriptions/set" }.count == 2)
            #expect(await gateway.connectionIdentity == connection)
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }

    @Test(arguments: [-32600, -32601])
    func unsupportedMethodRetriesOnlyAfterAnExplicitReconnect(code: Int64) async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await fixture.start()
        await fixture.rejectContentSubscriptions(code: code)
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        do {
            try await gateway.connectIfNeeded()
            let connection = try #require(await gateway.connectionIdentity)
            await fixture.acceptContentSubscriptions()
            await gateway.replaceContentSubscriptions(threadIDs: ["claude_b"], revision: 1)
            _ = try await gateway.readThread(threadID: "claude_b", includeTurns: false)
            await assertRejectedState(gateway, code: code)
            #expect(await fixture.acceptedConnections == 1)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/subscriptions/set" }.count == 1)
            #expect(await gateway.connectionIdentity == connection)
            await gateway.disconnect()
            try await gateway.connectIfNeeded()
            guard case .subscribed(let threads) = await gateway.contentSubscriptionState else {
                Issue.record("Reconnect must retry the current intent")
                await gateway.retire()
                await fixture.stop()
                return
            }
            #expect(threads == ["claude_b"])
            #expect(await fixture.acceptedConnections == 2)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/subscriptions/set" }.count == 2)
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }

    @Test func overflowingInitialIntentNeverSendsAnOversizedSetOrBlocksReads() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        do {
            await gateway.replaceContentSubscriptions(threadIDs: Set((0..<65).map { "claude_\($0)" }), revision: 1)
            try await gateway.connectIfNeeded()
            _ = try await gateway.readThread(threadID: "claude_b", includeTurns: false)
            try await assertRecoveredHistory(gateway)
            guard case .failed(.subscriptionCapacity(let actual, let limit)) = await gateway.contentSubscriptionState else {
                Issue.record("Overflow must remain failed")
                await gateway.retire()
                await fixture.stop()
                return
            }
            #expect(actual == 65 && limit == 64)
            #expect(await fixture.acceptedConnections == 1)
            #expect(await fixture.recordedRequests.allSatisfy { $0.method != "conversation/subscriptions/set" })
            let valid = Set((0..<64).map { "claude_\($0)" })
            await gateway.replaceContentSubscriptions(threadIDs: valid, revision: 2)
            try await gateway.connectIfNeeded()
            #expect(await fixture.acknowledgedContentSubscriptions == valid)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/subscriptions/set" }.count == 1)
            await gateway.retire()
            await fixture.stop()
        } catch {
            await gateway.retire()
            await fixture.stop()
            throw error
        }
    }

    private func assertRejectedState(_ gateway: GatewayClient, code: Int64) async {
        switch await gateway.contentSubscriptionState {
        case .unsupported(let actual):
            #expect((code == -32600 || code == -32601) && actual == Int(code))
        case .failed(.serverError(_, let actual)):
            #expect((code != -32600 && code != -32601) && actual == Int(code))
        default:
            Issue.record("A rejected set must never be exposed as subscribed or empty")
        }
    }

    private func assertRecoveredHistory(_ gateway: GatewayClient) async throws {
        struct Response: Decodable { let result: CodexAppServerV2.ThreadItemsListResponse }
        let bytes = try await gateway.historyPageData(method: "thread/items/list",
            params: .object(["threadId": .string("claude_b"), "limit": .number(10)]))
        let page = try JSONDecoder().decode(Response.self, from: bytes).result
        let entry = try #require(page.data.first)
        #expect(entry.turnId == "turn-b")
        #expect(entry.item == .agentMessage(id: "answer-b", text: "Recovered answer"))
        #expect(entry.isComplete == true)
    }
}
