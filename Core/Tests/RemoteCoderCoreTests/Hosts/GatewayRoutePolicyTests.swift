import Foundation
import Network
import Synchronization
import Testing
@testable import RemoteCoderCore

struct GatewayRoutePolicyTests {
    private let endpoint: GatewayLANEndpoint
    private let rotated: GatewayLANEndpoint
    private let firstPath = GatewayNetworkPath(identity: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)), localNetworkAvailable: true)
    private let secondPath = GatewayNetworkPath(identity: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)), localNetworkAvailable: true)
    private let unavailablePath = GatewayNetworkPath(identity: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3)), localNetworkAvailable: false)
    private let relay: GatewayRelayEndpoint

    init() throws {
        endpoint = try GatewayLANEndpoint(host: "mini.local", port: 8789, spkiSHA256: Data(repeating: 1, count: 32))
        rotated = try GatewayLANEndpoint(host: "mini.local", port: 8789, spkiSHA256: Data(repeating: 2, count: 32))
        relay = try GatewayRelayEndpoint(proxyHost: "192.0.2.10", proxyPort: 443, proxySPKISHA256: Data(repeating: 3, count: 32),
                                         targetHost: "mini.relay.example.com", targetPort: 20001, username: "relay", password: "secret")
    }

    @Test func routingPathIdentityUsesAvailabilityAndInterfaceTypes() {
        let cellular = GatewayRoutingPath(status: .satisfied, interfaceTypes: [.cellular], localNetworkAvailable: false)
        #expect(cellular == GatewayRoutingPath(status: .satisfied, interfaceTypes: [.cellular, .cellular], localNetworkAvailable: false))
        #expect(cellular != GatewayRoutingPath(status: .unsatisfied, interfaceTypes: [.cellular], localNetworkAvailable: false))
        #expect(cellular != GatewayRoutingPath(status: .satisfied, interfaceTypes: [.wifi], localNetworkAvailable: false))
        #expect(cellular != GatewayRoutingPath(status: .satisfied, interfaceTypes: [.cellular], localNetworkAvailable: true))
    }

    @Test func offersLANOnlyWithALearnedEndpointOnALocalNetwork() {
        let now = ContinuousClock.now
        var unlearned = GatewayRoutePolicy(endpoint: nil, usesLearnedRoutes: true)
        unlearned.networkPathChanged(firstPath)
        #expect(unlearned.lanCandidate(at: now) == nil)

        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        #expect(policy.lanCandidate(at: now) == nil)
        policy.networkPathChanged(firstPath)
        #expect(policy.lanCandidate(at: now) == endpoint)
        policy.networkPathChanged(unavailablePath)
        #expect(policy.lanCandidate(at: now) == nil)
    }

    @Test func aLANFailureFallsBackUntilTheRetryDelayPasses() {
        let failedAt = ContinuousClock.now
        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        policy.networkPathChanged(firstPath)
        policy.failed(.lan(endpoint), at: failedAt)
        #expect(policy.lanCandidate(at: failedAt + .seconds(299)) == nil)
        #expect(policy.lanCandidate(at: failedAt + .seconds(300)) == endpoint)
    }

    @Test func aNetworkChangeOrANewEndpointRetriesLANImmediately() {
        let failedAt = ContinuousClock.now
        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        policy.networkPathChanged(firstPath)
        policy.failed(.lan(endpoint), at: failedAt)
        policy.networkPathChanged(secondPath)
        #expect(policy.lanCandidate(at: failedAt) == endpoint)

        policy.failed(.lan(endpoint), at: failedAt)
        let learnedRotation = policy.learn(rotated)
        #expect(learnedRotation)
        #expect(policy.lanCandidate(at: failedAt) == rotated)
        let relearnedSameEndpoint = policy.learn(rotated)
        #expect(!relearnedSameEndpoint)
    }

    @Test func repeatedPathHintsPreserveFailedLANBackoff() {
        let failedAt = ContinuousClock.now
        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        policy.networkPathChanged(firstPath)
        policy.failed(.lan(endpoint), at: failedAt)
        for second in 1...299 {
            policy.networkPathChanged(firstPath)
            #expect(policy.lanCandidate(at: failedAt + .seconds(second)) == nil)
        }
        #expect(policy.lanCandidate(at: failedAt + .seconds(300)) == endpoint)
    }

    @Test func aStaleEndpointFailureDoesNotSuppressTheCurrentEndpoint() {
        let now = ContinuousClock.now
        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        policy.networkPathChanged(firstPath)
        _ = policy.learn(rotated)
        policy.failed(.lan(endpoint), at: now)
        #expect(policy.lanCandidate(at: now) == rotated)
    }

    @Test func onlyAProvenLANCarriesUploads() {
        let now = ContinuousClock.now
        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        policy.networkPathChanged(firstPath)
        #expect(policy.verifiedLAN == nil)
        policy.succeeded(.lan(endpoint))
        #expect(policy.verifiedLAN == endpoint)
        policy.networkPathChanged(firstPath)
        #expect(policy.verifiedLAN == endpoint)
        policy.networkPathChanged(secondPath)
        #expect(policy.verifiedLAN == nil)
        policy.succeeded(.lan(endpoint))
        policy.failed(.lan(endpoint), at: now)
        #expect(policy.verifiedLAN == nil)
        policy.succeeded(.lan(endpoint))
        _ = policy.learn(nil)
        #expect(policy.verifiedLAN == nil)
    }

    @Test func theRelayFollowsTheConfiguredRouteOnlyWithTheLANPinItEndsAt() {
        let now = ContinuousClock.now
        var unpinned = GatewayRoutePolicy(endpoint: nil, usesLearnedRoutes: true)
        _ = unpinned.learnRelay(relay)
        #expect(unpinned.connectionRoutes(at: now) == [.configured])

        var isolated = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: false)
        _ = isolated.learnRelay(relay)
        isolated.networkPathChanged(firstPath)
        #expect(isolated.connectionRoutes(at: now) == [.configured])

        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        policy.networkPathChanged(unavailablePath)
        #expect(policy.connectionRoutes(at: now) == [.configured])
        _ = policy.learnRelay(relay)
        #expect(policy.connectionRoutes(at: now) == [.configured, .relay(relay)])
        policy.networkPathChanged(firstPath)
        #expect(policy.connectionRoutes(at: now) == [.lan(endpoint), .configured, .relay(relay)])
        #expect(policy.requestRoutes(at: now) == [.configured, .relay(relay)])
    }

    @Test func aConfiguredPathFailureLeadsWithTheRelayForAGrowingCappedBackoff() {
        let start = ContinuousClock.now
        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        _ = policy.learnRelay(relay)
        var failedAt = start
        for delay in [60, 120, 240, 480, 600, 600] {
            policy.failed(.configured, at: failedAt)
            #expect(policy.connectionRoutes(at: failedAt + .seconds(delay - 1)) == [.relay(relay), .configured])
            #expect(policy.connectionRoutes(at: failedAt + .seconds(delay)) == [.configured, .relay(relay)])
            failedAt += .seconds(delay)
        }
        policy.succeeded(.configured)
        policy.failed(.configured, at: failedAt)
        #expect(policy.connectionRoutes(at: failedAt + .seconds(60)) == [.configured, .relay(relay)])
    }

    @Test func aRouteThatFailedStaysLastInsteadOfDisappearing() {
        let now = ContinuousClock.now
        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        _ = policy.learnRelay(relay)
        policy.failed(.relay(relay), at: now)
        #expect(policy.connectionRoutes(at: now) == [.configured, .relay(relay)])
        policy.failed(.configured, at: now)
        #expect(policy.connectionRoutes(at: now) == [.configured, .relay(relay)])
        policy.succeeded(.relay(relay))
        #expect(policy.connectionRoutes(at: now) == [.relay(relay), .configured])
    }

    @Test func aNewNetworkPathOrRelayRetriesItsRouteImmediately() throws {
        let now = ContinuousClock.now
        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        _ = policy.learnRelay(relay)
        policy.failed(.configured, at: now)
        policy.networkPathChanged(unavailablePath)
        #expect(policy.connectionRoutes(at: now) == [.configured, .relay(relay)])

        policy.failed(.configured, at: now)
        policy.failed(.relay(relay), at: now)
        let moved = try GatewayRelayEndpoint(proxyHost: "78.109.16.3", proxyPort: 443, proxySPKISHA256: relay.proxySPKISHA256,
            targetHost: relay.targetHost, targetPort: relay.targetPort, username: relay.username, password: relay.password)
        let learnedMove = policy.learnRelay(moved)
        #expect(learnedMove)
        #expect(policy.connectionRoutes(at: now) == [.relay(moved), .configured])
        let relearnedMove = policy.learnRelay(moved)
        #expect(!relearnedMove)
    }

    @Test func onlyABrokenNetworkPathCountsAsARouteFailure() {
        #expect(GatewayRoute.isPathFailure(URLError(.timedOut)))
        #expect(GatewayRoute.isPathFailure(URLError(.cannotFindHost)))
        #expect(GatewayRoute.isPathFailure(URLError(.secureConnectionFailed)))
        #expect(GatewayRoute.isPathFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EAUTH))))
        #expect(!GatewayRoute.isPathFailure(URLError(.cannotConnectToHost)))
        #expect(!GatewayRoute.isPathFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))))
        #expect(!GatewayRoute.isPathFailure(URLError(.cancelled)))
        #expect(!GatewayRoute.isPathFailure(URLError(.badServerResponse)))
        #expect(!GatewayRoute.isPathFailure(CancellationError()))
    }

    @Test func requestsFollowTheRouteTheGatewayConnectionUses() {
        let now = ContinuousClock.now
        var policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: true)
        _ = policy.learnRelay(relay)
        policy.connected(.relay(relay))
        policy.networkPathChanged(unavailablePath)
        #expect(policy.requestRoutes(at: now) == [.relay(relay), .configured])
        #expect(policy.connectionRoutes(at: now) == [.configured, .relay(relay)])
        policy.failed(.relay(relay), at: now)
        #expect(policy.requestRoutes(at: now) == [.configured, .relay(relay)])
        policy.connected(.relay(relay))
        policy.connected(.configured)
        #expect(policy.requestRoutes(at: now) == [.configured, .relay(relay)])
    }

    @Test func aFailureFromBeforeANetworkChangeLeavesTheRouteOrder() async throws {
        let fixture = try RoutesFixture(endpoint: endpoint, relay: relay)
        defer { fixture.remove() }
        var changes = await fixture.routes.networkPathChanges().makeAsyncIterator()
        let beforeChange = ContinuousClock.now
        fixture.updates.yield(unavailablePath)
        _ = await changes.next()

        await fixture.routes.failed(.configured, error: URLError(.timedOut), startedAt: beforeChange)
        #expect(await fixture.routes.connectionRoutes() == [.configured, .relay(relay)])
        await fixture.routes.failed(.configured, error: URLError(.timedOut), startedAt: .now)
        #expect(await fixture.routes.connectionRoutes() == [.relay(relay), .configured])
        await fixture.routes.retire()
    }

    @Test func aRouteThatFailedBeforeALaterRouteConnectedIsDemotedWhateverItsError() async throws {
        let fixture = try RoutesFixture(endpoint: endpoint, relay: relay)
        defer { fixture.remove() }
        var changes = await fixture.routes.networkPathChanges().makeAsyncIterator()
        fixture.updates.yield(unavailablePath)
        _ = await changes.next()
        let started = ContinuousClock.now
        #expect(await !fixture.routes.failed(.configured, error: URLError(.badServerResponse), startedAt: started))
        #expect(await fixture.routes.connectionRoutes() == [.configured, .relay(relay)])
        await fixture.routes.connected(over: .relay(relay), startedAt: started, afterFailing: [.configured])
        #expect(await fixture.routes.connectionRoutes() == [.relay(relay), .configured])
        await fixture.routes.retire()
    }

    @Test func anExchangeMovesOnAfterTransportFailuresAndStopsAtTheGatewaysAnswer() async throws {
        struct GatewayAnswer: Error {}
        let fixture = try RoutesFixture(endpoint: endpoint, relay: relay)
        defer { fixture.remove() }
        var changes = await fixture.routes.networkPathChanges().makeAsyncIterator()
        fixture.updates.yield(unavailablePath)
        _ = await changes.next()
        let request = URLRequest(url: try #require(URL(string: "http://\(fixture.configuredHost):8787/version")))
        let attempts = Mutex<[String]>([])
        func send(failing failingHost: String, with error: any Error) async throws -> String {
            try await fixture.routes.send(request, traffic: .read) { request, _ in
                let host = request.url?.host() ?? ""
                attempts.withLock { $0.append(host) }
                if host == failingHost { throw error }
                return host
            }
        }
        let configured = fixture.configuredHost, relayed = relay.targetHost

        #expect(try await send(failing: configured, with: URLError(.cancelled)) == relayed)
        #expect(try await send(failing: configured, with: URLError(.timedOut)) == relayed)
        #expect(try await send(failing: configured, with: URLError(.timedOut)) == relayed)
        await #expect(throws: GatewayAnswer.self) { try await send(failing: relayed, with: GatewayAnswer()) }
        #expect(attempts.withLock { $0 } == [configured, relayed, configured, relayed, relayed, relayed])
        await fixture.routes.retire()
    }

    @Test func aMutationMovesOnOnlyWhenItNeverReachedTheGateway() async throws {
        let fixture = try RoutesFixture(endpoint: endpoint, relay: relay)
        defer { fixture.remove() }
        var changes = await fixture.routes.networkPathChanges().makeAsyncIterator()
        fixture.updates.yield(unavailablePath)
        _ = await changes.next()
        let request = URLRequest(url: try #require(URL(string: "http://\(fixture.configuredHost):8787/accounts/a/remove")))
        let attempts = Mutex<[String]>([])
        func send(failing failingHost: String, with error: URLError) async throws -> String {
            try await fixture.routes.send(request, traffic: .mutation) { request, _ in
                let host = request.url?.host() ?? ""
                attempts.withLock { $0.append(host) }
                if host == failingHost { throw error }
                return host
            }
        }
        let configured = fixture.configuredHost, relayed = relay.targetHost

        await #expect(throws: URLError(.cancelled)) { try await send(failing: configured, with: URLError(.cancelled)) }
        await #expect(throws: URLError(.timedOut)) { try await send(failing: configured, with: URLError(.timedOut)) }
        #expect(try await send(failing: relayed, with: URLError(.cannotConnectToHost)) == configured)
        #expect(attempts.withLock { $0 } == [configured, configured, relayed, configured])
        await fixture.routes.retire()
    }

    @Test func aForcedRelayCarriesEveryRouteAndMovesAnyOtherConnectionOntoIt() async throws {
        let fixture = try RoutesFixture(endpoint: endpoint, relay: relay,
                                        policy: SharedGatewayPolicy(isIsolated: false, forcesRelay: true))
        defer { fixture.remove() }
        var changes = await fixture.routes.networkPathChanges().makeAsyncIterator()
        fixture.updates.yield(firstPath)
        _ = await changes.next()
        #expect(await fixture.routes.connectionRoutes() == [.relay(relay)])
        #expect(await fixture.routes.preferredRoute() == .relay(relay))
        #expect(await !fixture.routes.preferredRouteResponds(over: .relay(relay)))
        #expect(await fixture.routes.preferredRouteResponds(over: .configured))
        await fixture.routes.retire()
    }

    @Test func eachRouteRewritesOnlyTheAddressAndUpgradesToTLS() throws {
        let socket = try #require(URL(string: "ws://100.64.0.10:8787/ws?accountId=a&accountGeneration=1"))
        let upload = try #require(URL(string: "http://100.64.0.10:8787/uploads?name=notes.txt"))
        #expect(GatewayRoute.configured.url(replacingAddressOf: socket) == socket)
        #expect(GatewayRoute.lan(endpoint).url(replacingAddressOf: socket)?.absoluteString == "wss://mini.local:8789/ws?accountId=a&accountGeneration=1")
        #expect(GatewayRoute.relay(relay).url(replacingAddressOf: upload)?.absoluteString
            == "https://mini.relay.example.com:20001/uploads?name=notes.txt")
    }

    @Test func aRelayEndpointNeedsADialableProxyAPinAndACredential() throws {
        let valid = #"{"proxyHost":"192.0.2.10","proxyPort":443,"proxySpkiSha256":"qLfoLbRhblXl6JWyFO5QiGNqnt4JlGn5VU+ApdkGuVI=","targetHost":"mini.relay.example.com","targetPort":20001,"username":"relay","password":"secret"}"#
        let decoded = try JSONDecoder().decode(GatewayRelayEndpoint.self, from: Data(valid.utf8))
        #expect(decoded.targetPort == 20001)
        for (field, replacement) in [("192.0.2.10", "relay host"), ("20001", "0"), (#""relay""#, #""re:lay""#), (#""secret""#, #""""#),
                                     ("qLfoLbRhblXl6JWyFO5QiGNqnt4JlGn5VU+ApdkGuVI=", "AAAA")] {
            let json = valid.replacingOccurrences(of: field, with: replacement)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(GatewayRelayEndpoint.self, from: Data(json.utf8)) }
        }
    }
}

private struct RoutesFixture {
    let configuredHost = "100.64.0.1"
    let directory = URL.temporaryDirectory.appending(path: "gateway-routes-\(UUID())")
    let routes: GatewayRoutes
    let updates: AsyncStream<GatewayNetworkPath>.Continuation

    init(endpoint: GatewayLANEndpoint, relay: GatewayRelayEndpoint, policy: SharedGatewayPolicy = .production) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = GatewayHostConfiguration(id: UUID(), name: "Fixture", hostname: configuredHost, port: 8787,
                                            authToken: "fixture", transport: .trustedNetwork)
        let learned = { (key: String, value: Data) throws -> Data in
            try JSONSerialization.data(withJSONObject: ["learnedFrom": host.connectionSummary,
                                                        key: JSONSerialization.jsonObject(with: value)])
        }
        try learned("endpoint", JSONEncoder().encode(endpoint)).write(to: directory.appending(path: "lan-endpoint.json"))
        let storage = MemoryGatewayCredentials()
        try storage.write(learned("relay", JSONEncoder().encode(relay)))
        var updates: AsyncStream<GatewayNetworkPath>.Continuation?
        routes = GatewayRoutes(host: host, directory: directory, relayStorage: storage, policy: policy,
                               observeLocalNetwork: { updates = $0 })
        self.updates = try #require(updates)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
