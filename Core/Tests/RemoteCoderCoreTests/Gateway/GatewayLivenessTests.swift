import Foundation
import Network
import Synchronization
import Testing
@testable import RemoteCoderCore

@Suite(.timeLimit(.minutes(1)))
struct GatewayLivenessTests {
    @Test(arguments: [2500])
    func cellularRTTDoesNotDisconnectAnIdlePeer(milliseconds: Int) async throws {
        let peer = try DeviceToolSocketFixture(declarationReply: .accepted, repliesToPings: false,
                                              pongDelay: .milliseconds(milliseconds))
        let port = try await peer.start()
        let client = try client(port: port)
        do {
            try await client.connectIfNeeded()
            try await Task.sleep(for: .seconds(9))
            #expect(await client.isConnected)
            await client.retire()
            await peer.stop()
        } catch {
            await client.retire()
            await peer.stop()
            throw error
        }
    }

    @Test func bandwidthLimitedFrameDoesNotDisconnectAHealthyPeer() async throws {
        let peer = try DeviceToolSocketFixture(declarationReply: .accepted, repliesToPings: false,
                                              pongDelay: .milliseconds(1200))
        let upstreamPort = try await peer.start()
        let proxy = try BandwidthLimitedSocket(upstreamPort: upstreamPort, bytesPerSecond: 48 * 1024)
        let port = try await proxy.start()
        let client = try client(port: port)
        do {
            try await client.connectIfNeeded()
            let connection = try #require(await client.connectionIdentity)
            let disconnections = await client.disconnections
            var notifications = await client.notifications().makeAsyncIterator()
            let frame = CodexAppServerV2.JSONRPC.Message.notification(.init(method: "test/large-frame",
                params: .string(String(repeating: "x", count: 256 * 1024))))
            try await peer.send(.notification(.init(method: "connection/largeFrame",
                params: .object(["bytes": .number(Double(try JSONEncoder().encode(frame).count))]))))
            try await peer.send(frame)
            let received = try #require(await notifications.next())
            #expect(received.method == "test/large-frame")
            #expect(received.params?.stringValue?.utf8.count == 256 * 1024)
            #expect(await client.connectionIdentity == connection)
            #expect(await client.disconnections == disconnections)
            #expect(await client.isConnected)
            #expect(await peer.acceptedConnections == 1)
            await client.retire()
            await proxy.stop()
            await peer.stop()
        } catch {
            await client.retire()
            await proxy.stop()
            await peer.stop()
            throw error
        }
    }

    @Test func silentPeerIsDetectedWithoutWaitingForAnRPC() async throws {
        let peer = try DeviceToolSocketFixture(declarationReply: .accepted, repliesToPings: false)
        let port = try await peer.start()
        let client = try client(port: port)
        do {
            try await client.connectIfNeeded()
            let started = ContinuousClock.now
            let detected = await waitUntil(timeout: .seconds(20)) { await !client.isConnected }
            print("CELLULAR silent-peer detected=\(detected) elapsed=\(started.duration(to: .now))")
            #expect(detected)
            await client.retire()
            await peer.stop()
        } catch {
            await client.retire()
            await peer.stop()
            throw error
        }
    }

    @Test func pathChangesRespectAnOutstandingProbeAndForegroundResumptionStartsAFreshOne() async throws {
        let peer = try DeviceToolSocketFixture(declarationReply: .accepted, repliesToPings: false)
        let port = try await peer.start()
        let client = try client(port: port)
        var pings = peer.pings.makeAsyncIterator()
        do {
            try await client.connectIfNeeded()
            #expect(await pings.next() == 1)
            await client.networkPathChanged()
            await client.suspendLivenessChecks()
            await client.networkPathChanged()
            _ = try await client.call(method: "test/barrier", params: nil, timeout: .seconds(30))
            #expect(await peer.pingCount == 1)
            await client.resumeLivenessChecks()
            #expect(await pings.next() == 2)
            _ = try await client.call(method: "test/barrier", params: nil, timeout: .seconds(30))
            #expect(await peer.pingCount == 2)
            await client.retire()
            await client.networkPathChanged()
            #expect(await peer.pingCount == 2)
            await peer.stop()
            #expect(await pings.next() == nil)
        } catch {
            await client.retire()
            await peer.stop()
            throw error
        }
    }

    @Test func everyNetworkPathChangeReachesSubscribers() async throws {
        let directory = URL.temporaryDirectory.appending(path: "gateway-path-\(UUID())")
        let host = GatewayHostConfiguration(id: UUID(), name: "Fixture", hostname: "127.0.0.1", port: 1,
                                            authToken: "fixture", transport: .trustedNetwork)
        var updates: AsyncStream<GatewayNetworkPath>.Continuation?
        let routes = GatewayRoutes(host: host, directory: directory, relayStorage: MemoryGatewayCredentials(), policy: .production,
                                   observeLocalNetwork: { updates = $0 })
        let continuation = try #require(updates)
        var events = await routes.networkPathChanges().makeAsyncIterator()
        for available in [true, false] {
            continuation.yield(GatewayNetworkPath(identity: UUID(), localNetworkAvailable: available))
            #expect(await events.next() != nil)
        }
        await routes.retire()
        #expect(await events.next() == nil)
    }

    @Test func aSocketErrorClosesImmediatelyAfterAUsablePathUpdate() async throws {
        let peer = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await peer.start()
        let client = try client(port: port)
        do {
            try await client.connectIfNeeded()
            await client.networkPathChanged()
            #expect(await client.isConnected)
            let started = ContinuousClock.now
            await peer.stop()
            #expect(await waitUntil(timeout: .seconds(1)) { await !client.isConnected })
            print("CELLULAR transport-loss elapsed=\(started.duration(to: .now))")
            await client.retire()
        } catch {
            await client.retire()
            await peer.stop()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func realPathFlapsKeepOneOutstandingProbeAndCannotDelaySilentDeath(replies: Bool) async throws {
        let peer = try DeviceToolSocketFixture(declarationReply: .accepted, repliesToPings: false,
                                              pongDelay: replies ? .milliseconds(2500) : nil)
        let port = try await peer.start()
        let client = try client(port: port)
        do {
            try await client.connectIfNeeded()
            try #require(await waitUntil(timeout: .seconds(1)) { await peer.pingCount == 1 })
            let started = ContinuousClock.now
            for _ in 0..<45 {
                await client.networkPathChanged()
                await client.resumeLivenessChecks()
                try await Task.sleep(for: .milliseconds(200))
            }
            let replyPacedProbes = Int((started.duration(to: .now) / .milliseconds(2500)).rounded(.up))
            #expect(await client.isConnected == replies)
            #expect(await peer.pingCount <= (replies ? 1 + replyPacedProbes : 1))
            await client.retire()
            await peer.stop()
        } catch {
            await client.retire()
            await peer.stop()
            throw error
        }
    }

    @Test func aStalledRouteHandsOverToAFreshConnectionWithoutReportingADisconnect() async throws {
        let peer = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await peer.start()
        let client = try client(port: port)
        var events = await client.connectionEvents().makeAsyncIterator()
        do {
            try await client.connectIfNeeded()
            let original = try #require(await client.connectionIdentity)
            #expect(await events.next() == .connected(connection: original, route: .configured))
            let disconnections = await client.disconnections
            await client.suspendLivenessChecks()
            await peer.stallExistingConnections()
            await client.resumeLivenessChecks()
            let handover = try #require(await events.next())
            let replacement = try #require(await client.connectionIdentity)
            #expect(handover == .connected(connection: replacement, route: .configured))
            #expect(replacement != original)
            #expect(await client.isConnected)
            #expect(await client.disconnections == disconnections)
            #expect(await peer.acceptedConnections == 2)
            await client.retire()
            await peer.stop()
        } catch {
            await client.retire()
            await peer.stop()
            throw error
        }
    }

    @Test func anUpgradedPeerThatNeverSendsItsFirstFrameTimesOutAfterTheReadyWait() async throws {
        let peer = try DeviceToolSocketFixture(declarationReply: .accepted)
        await peer.withholdReady()
        let port = try await peer.start()
        let client = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
                                                 authToken: "fixture", hostLabel: "Cellular fixture"),
                                   routes: nil, timeouts: .init(request: .seconds(2)))
        let started = ContinuousClock.now
        let failure = await #expect(throws: GatewayClient.ClientError.self) { try await client.connectIfNeeded() }
        let elapsed = started.duration(to: .now)
        #expect({ if case .connectionFailed = failure { true } else { false } }())
        #expect(elapsed >= .seconds(12))
        #expect(elapsed < .seconds(15))
        #expect(await peer.acceptedConnections == 1)
        #expect(await !client.isConnected)
        await client.retire()
        await peer.stop()
    }

    @Test func aGatewayThatClosesBeforeItsFirstFrameFailsAsNotReady() async throws {
        let peer = try DeviceToolSocketFixture(declarationReply: .accepted)
        await peer.closeBeforeReady()
        let port = try await peer.start()
        let client = try client(port: port)
        let failure = await #expect(throws: GatewayClient.ClientError.self) { try await client.connectIfNeeded() }
        #expect({ if case .gatewayNotReady = failure { true } else { false } }())
        #expect(failure?.localizedDescription.hasPrefix("Cellular fixture closed the connection: ") == true)
        #expect(failure?.localizedDescription.localizedStandardContains("restarting") == false)
        await client.retire()
        await peer.stop()
    }

    @Test func aFailedHandoverFallsBackToAnOrdinaryDisconnect() async throws {
        let peer = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await peer.start()
        let client = try client(port: port)
        let events = EventRecorder()
        let stream = await client.connectionEvents()
        let recording = Task { for await event in stream { events.list.withLock { $0.append(event) } } }
        do {
            try await client.connectIfNeeded()
            let disconnections = await client.disconnections
            try await Task.sleep(for: .milliseconds(300))
            await peer.rejectInitialize()
            await peer.stallExistingConnections()
            let dropped = await waitUntil(timeout: .seconds(8)) { events.list.withLock { $0.contains(.disconnected) } }
            #expect(dropped)
            #expect(await peer.acceptedConnections == 2)
            #expect(await client.disconnections == disconnections + 1)
            #expect(await !client.isConnected)
            await client.retire()
            await recording.value
            await peer.stop()
        } catch {
            await client.retire()
            await peer.stop()
            throw error
        }
    }

    @Test func anUnansweredProbeIsSuspectOnlyAfterAPatienceScaledToTheRoundTrip() {
        let start = ContinuousClock.now
        var unsampled = GatewayReceiveDeadline(now: start)
        let first = start.advanced(by: .milliseconds(100))
        unsampled.recordPing(at: first)
        #expect(!unsampled.isSuspect(at: first.advanced(by: .milliseconds(3999))))
        #expect(unsampled.isSuspect(at: first.advanced(by: .seconds(4))))

        var fast = GatewayReceiveDeadline(now: start)
        fast.recordPing(at: start)
        fast.recordPong(at: start.advanced(by: .milliseconds(100)), processedAt: start.advanced(by: .milliseconds(100)))
        let next = start.advanced(by: .seconds(2))
        fast.recordPing(at: next)
        #expect(!fast.isSuspect(at: next.advanced(by: .milliseconds(1999))))
        #expect(fast.isSuspect(at: next.advanced(by: .seconds(2))))

        var slow = GatewayReceiveDeadline(now: start)
        slow.recordPing(at: start)
        for second in 1...4 { slow.recordWake(at: start.advanced(by: .seconds(second))) }
        slow.recordPong(at: start.advanced(by: .seconds(4)), processedAt: start.advanced(by: .seconds(4)))
        let later = start.advanced(by: .seconds(6))
        slow.recordPing(at: later)
        #expect(!slow.isSuspect(at: later.advanced(by: .milliseconds(5999))))
        #expect(slow.isSuspect(at: later.advanced(by: .seconds(6))))
    }

    @Test func eachUnansweredProbeClaimsOneStandby() {
        let start = ContinuousClock.now
        var deadline = GatewayReceiveDeadline(now: start)
        let first = start.advanced(by: .milliseconds(100))
        deadline.recordPing(at: first)
        let early = deadline.claimStandby(at: first.advanced(by: .seconds(3)))
        let due = deadline.claimStandby(at: first.advanced(by: .seconds(4)))
        let repeated = deadline.claimStandby(at: first.advanced(by: .seconds(5)))
        #expect(!early)
        #expect(due)
        #expect(!repeated)
        let answered = first.advanced(by: .seconds(5))
        for second in 1...5 { deadline.recordWake(at: first.advanced(by: .seconds(second))) }
        deadline.recordPong(at: answered, processedAt: answered)
        let next = answered.advanced(by: .seconds(2))
        deadline.recordPing(at: next)
        let nextProbe = deadline.claimStandby(at: next.advanced(by: .seconds(10)))
        #expect(nextProbe)
    }

    @Test func receiptsProcessingAndAnnouncedFramesDelayOrSuspendSuspicion() {
        let start = ContinuousClock.now
        var receiving = GatewayReceiveDeadline(now: start)
        receiving.recordPing(at: start)
        let lastFrame = start.advanced(by: .seconds(3))
        receiving.recordReceive(at: lastFrame)
        #expect(!receiving.isSuspect(at: lastFrame.advanced(by: .seconds(10))))
        let listening = lastFrame.advanced(by: .seconds(1))
        receiving.listen(at: listening)
        #expect(!receiving.isSuspect(at: listening.advanced(by: .milliseconds(3999))))
        #expect(receiving.isSuspect(at: listening.advanced(by: .seconds(4))))

        var transferring = GatewayReceiveDeadline(now: start)
        transferring.announceLargeFrame(bytes: 262_144, at: start)
        transferring.recordPing(at: start.advanced(by: .milliseconds(100)))
        #expect(!transferring.isSuspect(at: start.advanced(by: .seconds(10))))
    }

    @Test func virtualCellularJitterAndAQueuedFrameDoNotExpire() {
        let start = ContinuousClock.now
        var deadline = GatewayReceiveDeadline(now: start)
        let roundTrips = [600, 2500, 1200, 3500, 600, 2500]
        let frameStart = 6000
        let frameEnd = frameStart + Int((256.0 * 1024 / (48 * 1024)) * 1000)
        var nextPing = 0
        var pongAt: Int?
        var pingIndex = 0
        var frameReceived = false
        var falseDeaths = 0
        for millisecond in stride(from: 0, through: 30000, by: 100) {
            let now = start.advanced(by: .milliseconds(millisecond))
            if let due = pongAt, millisecond >= due {
                deadline.recordPong(at: now, processedAt: now)
                pongAt = nil
            }
            if !frameReceived, millisecond >= frameEnd {
                deadline.recordReceive(at: now)
                frameReceived = true
            }
            if millisecond % 1000 == 0 {
                deadline.recordWake(at: now)
                if pongAt != nil {
                    if deadline.hasExpired(at: now) { falseDeaths += 1 }
                } else if millisecond >= nextPing {
                    deadline.recordPing(at: now)
                    var arrival = millisecond + roundTrips[pingIndex % roundTrips.count]
                    if arrival >= frameStart, millisecond < frameEnd { arrival = max(arrival, frameEnd) }
                    pongAt = arrival
                    nextPing = millisecond + 2000
                    pingIndex += 1
                }
            }
        }
        #expect(falseDeaths == 0)
        #expect(pingIndex >= 8)
    }

    @Test func virtualSilentDeathIsBoundedAndFreshProbesResetTheRTTEstimate() {
        let start = ContinuousClock.now
        var deadline = GatewayReceiveDeadline(now: start)
        deadline.recordPing(at: start)
        for second in 1...4 { deadline.recordWake(at: start.advanced(by: .seconds(second))) }
        deadline.recordPong(at: start.advanced(by: .seconds(4)), processedAt: start.advanced(by: .seconds(4)))
        for second in 5...20 {
            let now = start.advanced(by: .seconds(second))
            deadline.recordWake(at: now)
            if second == 6 { deadline.recordPing(at: now) }
            #expect(!deadline.hasExpired(at: now))
        }
        let expiry = start.advanced(by: .seconds(21))
        deadline.recordWake(at: expiry)
        #expect(deadline.hasExpired(at: expiry))
        #expect(start.advanced(by: .seconds(4)).duration(to: expiry) == .seconds(17))
        deadline = GatewayReceiveDeadline(now: expiry)
        deadline.recordPing(at: expiry)
        for second in 22...28 {
            let now = start.advanced(by: .seconds(second))
            deadline.recordWake(at: now)
            #expect(!deadline.hasExpired(at: now))
        }
        let resetExpiry = start.advanced(by: .seconds(29))
        deadline.recordWake(at: resetExpiry)
        #expect(deadline.hasExpired(at: resetExpiry))
    }

    @Test func virtualPathFlapsCannotPostponeSilentDeath() {
        let start = ContinuousClock.now
        var deadline = GatewayReceiveDeadline(now: start)
        deadline.recordPing(at: start)
        for second in 1...4 { deadline.recordWake(at: start.advanced(by: .seconds(second))) }
        deadline.recordPong(at: start.advanced(by: .seconds(4)), processedAt: start.advanced(by: .seconds(4)))
        var probesDuringFlaps = 0
        for second in 5...21 {
            let now = start.advanced(by: .seconds(second))
            deadline.recordWake(at: now)
            if second >= 6, deadline.recordPing(at: now) { probesDuringFlaps += 1 }
            #expect(deadline.hasExpired(at: now) == (second == 21))
        }
        #expect(probesDuringFlaps == 1)
    }

    @Test(arguments: [(true, 30000), (false, 30000), (true, 600), (false, 600)])
    func suspendedRTTIsExcludedInEitherCallbackOrder(pongFirst: Bool, receivedMilliseconds: Int) {
        let start = ContinuousClock.now
        var deadline = GatewayReceiveDeadline(now: start)
        deadline.recordPing(at: start)
        deadline.recordWake(at: start.advanced(by: .seconds(1)))
        let resumed = start.advanced(by: .seconds(30))
        let received = start.advanced(by: .milliseconds(receivedMilliseconds))
        if pongFirst {
            deadline.recordPong(at: received, processedAt: resumed)
            deadline.recordWake(at: resumed)
        } else {
            deadline.recordWake(at: resumed)
            deadline.recordPong(at: received, processedAt: resumed)
        }
        for second in 31...40 {
            let now = start.advanced(by: .seconds(second))
            deadline.recordWake(at: now)
            if second == 32 { deadline.recordPing(at: now) }
            #expect(deadline.hasExpired(at: now) == (second == 40))
        }
    }

    @Test func delayedPongDuringFlapsUsesSocketTimeInsteadOfActorSchedulingTime() {
        let start = ContinuousClock.now
        var deadline = GatewayReceiveDeadline(now: start)
        let started = deadline.recordPing(at: start)
        #expect(started)
        for second in 1...3 {
            let now = start.advanced(by: .seconds(second))
            deadline.recordWake(at: now)
            let admitted = deadline.recordPing(at: now)
            #expect(!admitted)
        }
        deadline.recordPong(at: start.advanced(by: .milliseconds(2500)),
                            processedAt: start.advanced(by: .milliseconds(3250)))
        for second in 4...14 {
            let now = start.advanced(by: .seconds(second))
            deadline.recordWake(at: now)
            if second == 4 {
                let admitted = deadline.recordPing(at: now)
                #expect(admitted)
            }
            #expect(deadline.hasExpired(at: now) == (second == 14))
        }
    }

    @Test func completedProbeBurstsStillRespectTheTwoSecondCadence() {
        let start = ContinuousClock.now
        var deadline = GatewayReceiveDeadline(now: start)
        let started = deadline.recordPing(at: start)
        #expect(started)
        deadline.recordPong(at: start.advanced(by: .milliseconds(100)),
                            processedAt: start.advanced(by: .milliseconds(100)))
        for millisecond in stride(from: 200, through: 1900, by: 100) {
            let admitted = deadline.recordPing(at: start.advanced(by: .milliseconds(millisecond)))
            #expect(!admitted)
        }
        let next = deadline.recordPing(at: start.advanced(by: .seconds(2)))
        #expect(next)
    }

    @Test func cadenceRoundingCannotExtendTheSeventeenSecondBound() {
        let start = ContinuousClock.now
        var deadline = GatewayReceiveDeadline(now: start)
        deadline.recordPing(at: start)
        for second in 1...4 { deadline.recordWake(at: start.advanced(by: .seconds(second))) }
        let received = start.advanced(by: .milliseconds(4100))
        deadline.recordPong(at: received, processedAt: received)
        for second in 5...21 {
            let now = start.advanced(by: .seconds(second))
            deadline.recordWake(at: now)
            if second == 7 { deadline.recordPing(at: now) }
            #expect(!deadline.hasExpired(at: now))
        }
        let expiry = start.advanced(by: .milliseconds(21100))
        deadline.recordWake(at: expiry)
        #expect(deadline.hasExpired(at: expiry))
    }

    private func client(port: UInt16) throws -> GatewayClient {
        GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
                                   authToken: "fixture", hostLabel: "Cellular fixture"), routes: nil)
    }
}

private final class EventRecorder: Sendable {
    let list = Mutex<[GatewayConnectionEvent]>([])
}

private actor BandwidthLimitedSocket {
    private let listener: NWListener
    private let upstreamPort: UInt16
    private let bytesPerSecond: Int
    private let queue = DispatchQueue(label: "BandwidthLimitedSocket")
    private var ready: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []
    private var pumps: [Task<Void, Never>] = []
    private var stopped = false

    init(upstreamPort: UInt16, bytesPerSecond: Int) throws {
        self.upstreamPort = upstreamPort
        self.bytesPerSecond = bytesPerSecond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
            listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            listener.start(queue: queue)
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port { ready?.resume(returning: port.rawValue); ready = nil }
        case .failed(let error):
            ready?.resume(throwing: error)
            ready = nil
        default: break
        }
    }

    private func accept(_ downstream: NWConnection) {
        guard !stopped else { downstream.cancel(); return }
        guard let port = NWEndpoint.Port(rawValue: upstreamPort) else { downstream.cancel(); return }
        let upstream = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        connections.append(contentsOf: [downstream, upstream])
        downstream.start(queue: queue)
        upstream.start(queue: queue)
        pumps.append(Task { await forward(from: downstream, to: upstream, limited: false) })
        pumps.append(Task { await forward(from: upstream, to: downstream, limited: true) })
    }

    private func forward(from source: NWConnection, to destination: NWConnection, limited: Bool) async {
        do {
            while !Task.isCancelled, !stopped {
                let data: Data? = try await withCheckedThrowingContinuation { continuation in
                    source.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: complete && data?.isEmpty != false ? nil : data) }
                    }
                }
                guard let data, !data.isEmpty else { break }
                if limited {
                    try await Task.sleep(for: .seconds(Double(data.count) / Double(bytesPerSecond)))
                }
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    destination.send(content: data, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                }
            }
        } catch {}
        source.cancel()
        destination.cancel()
    }

    func stop() async {
        stopped = true
        listener.cancel()
        for pump in pumps { pump.cancel() }
        for connection in connections { connection.cancel() }
        for pump in pumps { await pump.value }
        pumps.removeAll()
        connections.removeAll()
    }
}
