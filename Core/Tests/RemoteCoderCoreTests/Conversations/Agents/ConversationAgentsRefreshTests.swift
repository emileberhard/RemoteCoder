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

    @Test func placementDuringAReadCoalescesIntoOneFreshTrailingRead() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        await fixture.holdRequests("conversation/agents/list")
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let model = ConversationAgentsModel(address: .init(hostID: UUID(), threadID: "parent"), gateway: gateway)
        do {
            let refresh = Task { await model.refresh() }
            for await request in fixture.requests where request.method == "conversation/agents/list" { break }
            model.refreshAfterPlacement()
            model.refreshAfterPlacement()
            await fixture.setResult(.object(["agents": .array([]), "revision": .string("2"), "warnings": .array([])]), method: "conversation/agents/list")
            try await fixture.releaseRequests(result: page)
            await refresh.value
            #expect(model.hasLoaded && model.agents.isEmpty && !model.isRefreshing)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/agents/list" }.count == 2)
            #expect(await fixture.recordedNotifications.allSatisfy { $0.method != "$/cancelRequest" })
            await fixture.setResult(page, method: "conversation/agents/list")
            model.refreshAfterPlacement()
            await model.refreshIfNeeded()
            #expect(model.agents.count == 1)
            #expect(await fixture.recordedRequests.filter { $0.method == "conversation/agents/list" }.count == 3)
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

    @Test func remoteRowsReplaceIntentsAndFailedReadsRetainCoverage() async throws {
        let parentHost = UUID(), childHost = UUID()
        let parentFixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let childFixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let parentPort = try await parentFixture.start()
        let childPort = try await childFixture.start()
        let parentGateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(parentPort)")),
            authToken: "fixture", hostLabel: "Parent"), routes: nil)
        let childGateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(childPort)")),
            authToken: "fixture", hostLabel: "Child"), routes: nil)
        let parent: JSONValue = .object(["hostId": .string(parentHost.uuidString), "threadId": .string("parent")])
        let stub: JSONValue = .object(["id": .string("job"), "kind": .string("remote_intent"), "jobId": .string("job"),
            "ownerThreadId": .string("parent"), "provider": .string("codex"), "source": .string("remote_intent"),
            "title": .string("Remote child"), "state": .string("unknown"),
            "capabilities": .object(["inspect": .bool(false), "openConversation": .bool(false), "message": .bool(false),
                                    "continueWork": .bool(false), "stop": .bool(false), "askParent": .bool(false)]),
            "ownerHostId": .string(childHost.uuidString), "parent": parent, "intentState": .string("admitted"),
            "lastActiveAt": .number(1_793_181_600)])
        var real = try #require(page.objectValue?["agents"]?.arrayValue?.first?.objectValue)
        real["jobId"] = .string("job")
        real["ownerHostId"] = .string(childHost.uuidString)
        real["threadId"] = .string("child")
        real["parent"] = parent
        let parentPage: JSONValue = .object(["agents": .array([stub]), "warnings": .array([]), "revision": .string("1")])
        let childPage: JSONValue = .object(["agents": .array([.object(real)]), "warnings": .array([]), "revision": .string("1")])
        let model = ConversationAgentsModel(address: .init(hostID: parentHost, threadID: "parent"), gateway: parentGateway)
        model.clusterHosts = { [.init(id: parentHost, name: "Parent", gateway: parentGateway, supportsCrossHost: true),
                                .init(id: childHost, name: "Child", gateway: childGateway, supportsCrossHost: true)] }
        do {
            await parentFixture.setResult(parentPage, method: "conversation/agents/list")
            await childFixture.setResult(childPage, method: "conversation/agents/list")
            await model.refresh()
            #expect(model.agents.count == 1)
            #expect(model.agents.first?.threadId == "child")
            #expect(model.coverage.first { $0.id == childHost }?.name == "Child")
            #expect(model.coverage.allSatisfy { $0.state == .ok })
            await childFixture.failCapacity("conversation/agents/list", count: 1, retryable: false)
            await model.refresh()
            #expect(model.agents.first?.threadId == "child")
            #expect(model.coverage.first { $0.id == childHost }?.state == .stale)
            #expect(model.coverage.first { $0.id == childHost }?.staleThrough != nil)
            var unknown = try #require(stub.objectValue)
            unknown["intentState"] = .string("unknown")
            await parentFixture.setResult(.object(["agents": .array([.object(unknown)]), "warnings": .array([]), "revision": .string("2")]), method: "conversation/agents/list")
            await childFixture.failCapacity("conversation/agents/list", count: 1, retryable: false)
            await model.refresh()
            #expect(model.agents.first?.isStub == true)
            #expect(model.agents.first?.state == .unknown)
            await parentGateway.retire()
            await childGateway.retire()
            await parentFixture.stop()
            await childFixture.stop()
        } catch {
            await parentGateway.retire()
            await childGateway.retire()
            await parentFixture.stop()
            await childFixture.stop()
            throw error
        }
    }

    private var page: JSONValue {
        .object(["agents": .array([.object(["id": .string("worker"), "ownerThreadId": .string("parent"),
            "provider": .string("codex"), "source": .string("native"), "title": .string("Worker"), "state": .string("working"),
            "capabilities": .object(["inspect": .bool(true), "openConversation": .bool(false), "message": .bool(false),
                "continueWork": .bool(false), "stop": .bool(false), "askParent": .bool(false)])])]),
            "revision": .string("1"), "warnings": .array([])])
    }
}
