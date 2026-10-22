import Foundation
import Synchronization
import Testing
@testable import RemoteCoderCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ConversationAgentsRefreshTests {
    @Test func concurrentSurfacesShareOneReadAndReuseItsFreshResult() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        await fixture.holdRequests("conversation/agents/list")
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let clock = Mutex(Date(timeIntervalSince1970: 100))
        let model = ConversationAgentsModel(address: .init(hostID: UUID(), threadID: "parent"), gateway: gateway,
            now: { clock.withLock { $0 } })
        do {
            let first = Task { await model.refreshIfNeeded() }
            let second = Task { await model.refreshIfNeeded() }
            for await request in fixture.requests where request.method == "conversation/agents/list" { break }
            first.cancel()
            await first.value
            #expect(model.isRefreshing)
            #expect(!model.hasLoaded)
            #expect(model.summary == nil)
            try await fixture.releaseRequests(result: page)
            await second.value
            #expect(model.hasLoaded)
            #expect(model.summary?.total == 1)
            #expect(await fixture.recordedNotifications.allSatisfy { $0.method != "$/cancelRequest" })
            await fixture.setResult(page, method: "conversation/agents/list")
            await model.refreshIfNeeded()
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/agents/list" }.count == 1)
            clock.withLock { $0.addTimeInterval(16) }
            await model.refreshIfNeeded()
            #expect(model.error == nil)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/agents/list" }.count == 2)
            await model.refresh()
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/agents/list" }.count == 3)
            model.invalidate()
            await model.refreshIfNeeded()
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/agents/list" }.count == 4)
            await fixture.failCapacity("conversation/agents/list", count: 1, retryable: false)
            await model.refresh()
            #expect(model.error != nil)
            #expect(model.agents.map(\.id) == ["worker"])
            await gateway.retire()
            await fixture.stop()
        } catch { await gateway.retire(); await fixture.stop(); throw error }
    }

    @Test func lastCancelledSurfaceAbandonsTheSharedRead() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        await fixture.advertiseCancellation(true)
        await fixture.holdRequests("conversation/agents/list")
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let model = ConversationAgentsModel(address: .init(hostID: UUID(), threadID: "parent"), gateway: gateway)
        do {
            let refresh = Task { await model.refreshIfNeeded() }
            for await request in fixture.requests where request.method == "conversation/agents/list" { break }
            refresh.cancel()
            await refresh.value
            #expect(!model.isRefreshing && !model.hasLoaded)
            #expect(model.summary == nil)
            for await notification in fixture.notifications where notification.method == "$/cancelRequest" { break }
            _ = try await gateway.call(method: "host/info", params: nil, timeout: .seconds(1))
            #expect(await fixture.recordedNotifications.filter { $0.method == "$/cancelRequest" }.count == 1)
            await gateway.retire()
            await fixture.stop()
        } catch { await gateway.retire(); await fixture.stop(); throw error }
    }

    @Test func invalidatingAnInFlightReadRefreshesItsExistingWaiters() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        await fixture.advertiseCancellation(true)
        await fixture.holdRequests("conversation/agents/list")
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let model = ConversationAgentsModel(address: .init(hostID: UUID(), threadID: "parent"), gateway: gateway)
        do {
            let refresh = Task { await model.refreshIfNeeded() }
            for await request in fixture.requests where request.method == "conversation/agents/list" { break }
            model.observeChildren([])
            model.observeChildren(["new-child"])
            for await request in fixture.requests where request.method == "conversation/agents/list" { break }
            try await fixture.releaseRequests(result: page)
            await refresh.value
            #expect(model.error == nil && model.summary?.total == 1)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/agents/list" }.count == 2)
            await gateway.retire()
            await fixture.stop()
        } catch { await gateway.retire(); await fixture.stop(); throw error }
    }

    @Test func concurrentSurfacesShareTheRequestThroughoutCapacityRecovery() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        await fixture.holdRequests("conversation/agents/list")
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let model = ConversationAgentsModel(address: .init(hostID: UUID(), threadID: "parent"), gateway: gateway)
        do {
            let prefetch = Task { await model.refreshIfNeeded() }
            for await request in fixture.requests where request.method == "conversation/agents/list" { break }
            let release = Task { @MainActor in
                try await fixture.refuseHeldRequestsForCapacity()
                #expect(!model.hasLoaded)
                #expect(model.error == nil)
                #expect(await waitUntil {
                    await fixture.recordedRequests.filter { $0.method == "conversation/agents/list" }.count == 2
                })
                try await fixture.releaseRequests(result: page)
            }
            await model.refreshIfNeeded()
            try await release.value
            await prefetch.value
            #expect(model.hasLoaded && model.summary?.total == 1 && model.error == nil)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/agents/list" }.count == 2)
            await gateway.retire()
            await fixture.stop()
        } catch { await gateway.retire(); await fixture.stop(); throw error }
    }

    private var page: JSONValue {
        .object(["agents": .array([.object(["id": .string("worker"), "ownerThreadId": .string("parent"),
            "provider": .string("codex"), "source": .string("native"), "title": .string("Worker"), "state": .string("working"),
            "capabilities": .object(["inspect": .bool(true), "openConversation": .bool(false), "message": .bool(false),
                "continueWork": .bool(false), "stop": .bool(false), "askParent": .bool(false)])])]),
            "revision": .string("1"), "warnings": .array([])])
    }
}
