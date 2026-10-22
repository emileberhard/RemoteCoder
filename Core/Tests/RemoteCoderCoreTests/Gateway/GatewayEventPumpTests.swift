import Foundation
import Network
import Testing
@testable import RemoteCoderCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GatewayEventPumpTests {
    @Test func retiringAnExplicitReplayReleasesItsClaimForTheReplacementPump() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let owner = await sessions.session(threadID: "claude_b")
        defer { await sessions.invalidate(threadID: "claude_b") }
        let socket = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await socket.start()
        let client = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let sink = PausedReplaySink(sessions: sessions)
        let pump = GatewayEventPump(gateway: client, conversations: sessions, sink: sink)
        defer {
            sink.releaseDelivery()
            let stopped = pump.stop()
            await client.retire()
            await socket.stop()
            for task in stopped { await task.value }
        }
        pump.startIfNeeded()
        try await eventually { await sink.connected }
        let turns = TurnRegistry()
        _ = turns.adopt(threadID: "claude_b", turnID: "turn-b")
        let jobID = try #require(turns.turn(forThread: "claude_b")?.jobID)
        try #require(turns.claimReplay(jobID: jobID))
        let replay = Task {
            do {
                try await pump.replayThread(afterSequence: 0, epoch: "fixture", threadID: "claude_b", limit: 2_000)
                return false
            } catch is CancellationError {
                turns.releaseReplay(jobID: jobID)
                return true
            } catch {
                turns.releaseReplay(jobID: jobID)
                Issue.record(error)
                return false
            }
        }
        defer { sink.releaseDelivery(); replay.cancel(); _ = await replay.value }
        try await eventually { await sink.waitingForDelivery }
        let oldTasks = pump.stop()
        defer { for task in oldTasks { await task.value } }
        pump.startIfNeeded()
        sink.releaseDelivery()
        #expect(await replay.value)
        #expect(!replay.isCancelled)
        #expect(await owner.snapshot().messages.isEmpty)

        try #require(turns.claimReplay(jobID: jobID))
        try await pump.replayThread(afterSequence: 0, epoch: "fixture", threadID: "claude_b", limit: 2_000)
        #expect(await owner.snapshot().messages.map(\.text) == ["Recovered answer"])
        #expect(await socket.recordedRequests.filter { $0.method == "daemon/replayNotifications" }.count == 2)
    }

    @Test func aStalledRouteIsReplacedWithoutReportingALostLinkAndReplaysFromItsCursor() async throws {
        try await withRecordingPump(timeouts: GatewayClient.Timeouts()) { _, socket, sink in
            #expect(await waitUntil { sink.links.last == .connected })
            try await socket.send(.notification(.init(method: "daemon/ready",
                params: .object(["notificationEpoch": .string("fixture"), "notificationSequence": .number(5)]))))
            await socket.stallExistingConnections()
            #expect(await waitUntil(timeout: .seconds(10)) {
                await socket.recordedRequests.contains { $0.method == "daemon/replayNotifications" }
            })
            let replay = await socket.recordedRequests.first { $0.method == "daemon/replayNotifications" }
            #expect(replay?.params?.objectValue?["afterSequence"] == .number(5))
            #expect(await waitUntil { sink.replayedEvents == 1 })
            #expect(await socket.acceptedConnections == 2)
            #expect(!sink.links.contains(.disconnected))
            #expect(!sink.links.contains(.reconnecting))
            #expect(sink.links.last == .connected)
        }
    }

    @Test func aPlannedRestartReadsAsRestartingUntilTheGatewayAdmitsTheClientAgain() async throws {
        try await withRecordingPump(timeouts: GatewayClient.Timeouts()) { _, socket, sink in
            #expect(await waitUntil { sink.connectivity.last == .connected(.configured) })

            await socket.closeBeforeReady(code: .privateCode(4012))
            await socket.closeConnections(code: .privateCode(4012))
            #expect(await waitUntil { sink.connectivity.last == .restarting })
            #expect(await waitUntil(timeout: .seconds(10)) { await socket.acceptedConnections >= 4 })
            #expect(sink.connectivity.last == .restarting)

            await socket.admitConnections()
            #expect(await waitUntil(timeout: .seconds(10)) { sink.connectivity.last == .connected(.configured) })
            #expect(!sink.connectivity.drop { $0 != .connected(.configured) }.contains(.disconnected))
        }
    }

    @Test func aRestartThatOutlastsItsWindowReadsAsDisconnectedWhileTheGatewayStillRefuses() async throws {
        var timeouts = GatewayClient.Timeouts()
        timeouts.restartWindow = .seconds(1)
        try await withRecordingPump(timeouts: timeouts) { client, socket, sink in
            try #require(await waitUntil(timeout: .seconds(30)) { sink.connectivity.last == .connected(.configured) })
            var events = await client.connectionEvents().makeAsyncIterator()
            await socket.closeBeforeReady(code: .privateCode(4012))
            await socket.closeConnections(code: .privateCode(4012))
            #expect(await events.next() == .restarting)
            #expect(await events.next() == .disconnected)
            try #require(await waitUntil(timeout: .seconds(30)) { sink.connectivity.last == .disconnected })
            #expect(sink.connectivity.contains(.restarting))
            #expect(await socket.acceptedConnections >= 2)
            let error = await #expect(throws: GatewayClient.ClientError.self) { try await client.connectIfNeeded() }
            #expect({ if case .gatewayNotReady = error { true } else { false } }())
            #expect(await client.connectivity == .disconnected)
        }
    }

    private func withRecordingPump(timeouts: GatewayClient.Timeouts,
                                   _ body: (GatewayClient, DeviceToolSocketFixture, LinkRecordingSink) async throws -> Void)
        async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let socket = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await socket.start()
        let client = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil, timeouts: timeouts)
        let sink = LinkRecordingSink()
        let pump = GatewayEventPump(gateway: client, conversations: sessions, sink: sink)
        defer {
            let stopped = pump.stop()
            await client.retire()
            await socket.stop()
            for task in stopped { await task.value }
        }
        pump.startIfNeeded()
        try await body(client, socket, sink)
    }
}

@MainActor
private final class LinkRecordingSink: GatewayEventSink {
    let isRetired = false
    let acceptsConnectionReports = true
    private(set) var links: [GatewayEventPump.Link] = []
    private(set) var connectivity: [GatewayConnectivity] = []
    private(set) var replayedEvents = 0

    func gatewayConnectionChanged(_ link: GatewayEventPump.Link, connection: UUID?) { links.append(link) }
    func gatewayConnectivityChanged(_ connectivity: GatewayConnectivity) {
        if self.connectivity.last != connectivity { self.connectivity.append(connectivity) }
    }
    func gatewayNetworkPathChanged() {}
    func gatewayActivityRefreshRequested() {}
    func apply(gatewayEvent event: RoutedGatewayEvent, replay: Bool) async { if replay { replayedEvents += 1 } }
    func gatewayThreadClosed(_ threadID: String, receipt: GatewayWireReceipt?) {}
    func gatewayQuestionsChanged(_ change: ServerNotification.QuestionsChanged) {}
    func defersReplay(_ event: RoutedGatewayEvent) -> Bool { false }
    func reconcile(gap: ReplayProgress.Gap) async {}
}

@MainActor
private final class PausedReplaySink: GatewayEventSink {
    let isRetired = false
    let acceptsConnectionReports = true
    private(set) var connected = false
    private var paused = true
    private var continuation: CheckedContinuation<Void, Never>?
    private let sessions: ConversationSessions

    init(sessions: ConversationSessions) { self.sessions = sessions }

    var waitingForDelivery: Bool { continuation != nil }

    func releaseDelivery() {
        paused = false
        continuation?.resume()
        continuation = nil
    }

    func apply(gatewayEvent event: RoutedGatewayEvent, replay: Bool) async {
        #expect(replay)
        if paused { await withCheckedContinuation { continuation = $0 } }
        guard GatewayEventPump.delivery?.isCurrent == true else { return }
        guard case .turnEvent(let event) = event else { Issue.record("Expected a replayed turn event"); return }
        await sessions.ingest(event, replay: replay)
    }

    func gatewayConnectionChanged(_ link: GatewayEventPump.Link, connection: UUID?) { connected = link == .connected }
    func gatewayConnectivityChanged(_ connectivity: GatewayConnectivity) {}
    func gatewayNetworkPathChanged() {}
    func gatewayActivityRefreshRequested() {}
    func gatewayThreadClosed(_ threadID: String, receipt: GatewayWireReceipt?) {}
    func gatewayQuestionsChanged(_ change: ServerNotification.QuestionsChanged) {}
    func defersReplay(_ event: RoutedGatewayEvent) -> Bool { false }
    func reconcile(gap: ReplayProgress.Gap) async {}
}
