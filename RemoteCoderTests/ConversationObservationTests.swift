import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct ConversationObservationTests {
    @Test(.timeLimit(.minutes(1))) func cancelledSelectionClosesItsLateHandleOnTheWire() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let server = try FakeGatewayServer()
        let url = try await server.startURL()
        let gateway = GatewayClient(config: .init(url: url, authToken: "test", hostLabel: "test"), routes: nil)
        let coordinator = ConversationObservationCoordinator(gateway: gateway,
            history: GatewayHistoryService(gateway: gateway,
                cache: HistoryPageCache(directory: temporary.storage.root.appending(path: "history-pages"))),
            capacity: 1)
        let id = UUID()
        let checkpoints = ConversationCheckpointStore(hostID: UUID(), storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let session = ConversationSession(conversationID: id, threadID: "thread", checkpoints: checkpoints,
            checkpointGeneration: await checkpoints.generation(for: id))
        try await gateway.connectIfNeeded()
        coordinator.connected(try #require(await gateway.connectionIdentity))
        coordinator.observe(["thread": session])
        await server.waitForSubscribe()
        coordinator.observe([:])
        try await server.releaseSubscribe(malformed: false)
        let closed = await server.waitForClose()
        #expect(closed == "observer-1")
        #expect(coordinator.state(of: "thread") == .detached)
        await gateway.disconnect()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1))) func twoObservedThreadsAttachAndReleaseIndependently() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let server = try FakeGatewayServer()
        let url = try await server.startURL()
        let gateway = GatewayClient(config: .init(url: url, authToken: "test", hostLabel: "test"), routes: nil)
        let coordinator = ConversationObservationCoordinator(gateway: gateway,
            history: GatewayHistoryService(gateway: gateway,
                cache: HistoryPageCache(directory: temporary.storage.root.appending(path: "history-pages"))),
            capacity: 2)
        let checkpoints = ConversationCheckpointStore(hostID: UUID(), storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let firstID = UUID()
        let secondID = UUID()
        let first = ConversationSession(conversationID: firstID, threadID: "thread-a", checkpoints: checkpoints,
            checkpointGeneration: await checkpoints.generation(for: firstID))
        let second = ConversationSession(conversationID: secondID, threadID: "thread-b", checkpoints: checkpoints,
            checkpointGeneration: await checkpoints.generation(for: secondID))
        try await gateway.connectIfNeeded()
        coordinator.connected(try #require(await gateway.connectionIdentity))
        coordinator.observe(["thread-a": first, "thread-b": second])
        await server.waitForSubscribes(2)
        #expect(coordinator.state(of: "thread-a") == .attaching)
        #expect(coordinator.state(of: "thread-b") == .attaching)
        coordinator.observe(["thread-b": second])
        #expect(coordinator.state(of: "thread-a") == .detached)
        #expect(coordinator.state(of: "thread-b") == .attaching)
        try await server.releaseSubscribe(threadID: "thread-a")
        #expect(await server.waitForClose() == "observer-1")
        #expect(coordinator.state(of: "thread-a") == .detached)
        #expect(coordinator.state(of: "thread-b") == .attaching)
        await gateway.disconnect()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1))) func malformedCheckpointClosesTheRegistrationBeforeFailing() async throws {
        let server = try FakeGatewayServer()
        let url = try await server.startURL()
        let gateway = GatewayClient(config: .init(url: url, authToken: "test", hostLabel: "test"), routes: nil)
        let request = Task { try await gateway.subscribe(threadID: "thread") }
        await server.waitForSubscribe()
        try await server.releaseSubscribe(malformed: true)
        #expect(await server.waitForClose() == "observer-1")
        do { _ = try await request.value; Issue.record("Malformed checkpoint was accepted") }
        catch is DecodingError {} catch { Issue.record(error) }
        await gateway.disconnect()
        await server.stop()
    }
    @Test(.timeLimit(.minutes(1))) func timedOutSubscribeClosesItsLateRegistration() async throws {
        let server = try FakeGatewayServer()
        let url = try await server.startURL()
        let gateway = GatewayClient(config: .init(url: url, authToken: "test", hostLabel: "test"), routes: nil,
            timeouts: .init(history: .milliseconds(300)))
        let request = Task { try await gateway.subscribe(threadID: "thread") }
        await server.waitForSubscribe()
        do { _ = try await request.value; Issue.record("Expected the bounded subscribe timeout") }
        catch GatewayClient.ClientError.requestTimedOut(let method) { #expect(method == "thread/subscribe") }
        catch { Issue.record(error) }
        try await server.releaseSubscribe(malformed: false)
        #expect(await server.waitForClose() == "observer-1")
        #expect(await gateway.isConnected)
        await gateway.disconnect()
        await server.stop()
    }
}
