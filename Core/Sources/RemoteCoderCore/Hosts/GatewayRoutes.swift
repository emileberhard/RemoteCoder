import Foundation
import Network
import OSLog
import Security
import Synchronization

enum GatewayRoute: Equatable, Sendable {
    case lan(GatewayLANEndpoint)
    case configured
    case relay(GatewayRelayEndpoint)

    enum Kind: Sendable {
        case lan
        case configured
        case relay
    }

    var kind: Kind {
        switch self {
        case .lan: .lan
        case .configured: .configured
        case .relay: .relay
        }
    }

    func configure(_ configuration: URLSessionConfiguration) {
        switch self {
        case .configured: break
        case .lan: Self.keepOnLocalNetwork(configuration)
        case .relay(let relay): configuration.proxyConfigurations = [relay.proxyConfiguration()]
        }
    }

    static func keepOnLocalNetwork(_ configuration: URLSessionConfiguration) {
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
    }

    func url(replacingAddressOf url: URL) -> URL? {
        let host: String
        let port: Int
        switch self {
        case .configured: return url
        case .lan(let endpoint): (host, port) = (endpoint.host, endpoint.port)
        case .relay(let relay): (host, port) = (relay.targetHost, Int(relay.targetPort))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "ws" || components.scheme == "wss" ? "wss" : "https"
        components.host = host
        components.port = port
        return components.url
    }

    static func isPathFailure(_ error: any Error) -> Bool {
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet,
                 .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .internationalRoamingOff,
                 .dataNotAllowed, .callIsActive:
                return true
            default:
                return false
            }
        }
        let error = error as NSError
        return error.domain == NSPOSIXErrorDomain && error.code != Int(ECONNREFUSED)
    }

    static func neverReachedGateway(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .internationalRoamingOff,
             .dataNotAllowed, .callIsActive:
            true
        default:
            false
        }
    }
}

enum GatewayTraffic: Sendable {
    case read
    case exchange
    case mutation
    case download
}

struct GatewayNetworkPath: Equatable, Sendable {
    let identity: UUID
    let localNetworkAvailable: Bool
}

struct GatewayRoutePolicy: Sendable {
    static let lanRetryDelay = Duration.seconds(300)
    static let firstFallbackRetryDelay = Duration.seconds(60)
    static let longestFallbackRetryDelay = Duration.seconds(600)

    private enum LANState: Sendable {
        case untested
        case verified
        case failed(ContinuousClock.Instant)
    }

    private struct PathFailures: Sendable {
        private var count = 0
        private var lastAt: ContinuousClock.Instant?

        var isEmpty: Bool { lastAt == nil }

        func isBackingOff(at now: ContinuousClock.Instant) -> Bool {
            guard let lastAt else { return false }
            let delay = min(GatewayRoutePolicy.firstFallbackRetryDelay * (1 << min(count - 1, 4)),
                            GatewayRoutePolicy.longestFallbackRetryDelay)
            return lastAt.duration(to: now) < delay
        }

        mutating func record(at now: ContinuousClock.Instant) {
            count += 1
            lastAt = now
        }
    }

    let usesLearnedRoutes: Bool
    private var endpoint: GatewayLANEndpoint?
    private var relay: GatewayRelayEndpoint?
    private var networkPath: GatewayNetworkPath?
    private var state = LANState.untested
    private var configuredFailures = PathFailures()
    private var relayFailures = PathFailures()
    private var lastConnectedFallback: GatewayRoute?

    init(endpoint: GatewayLANEndpoint?, usesLearnedRoutes: Bool) {
        self.endpoint = endpoint
        self.usesLearnedRoutes = usesLearnedRoutes
    }

    func lanCandidate(at now: ContinuousClock.Instant) -> GatewayLANEndpoint? {
        guard usesLearnedRoutes, networkPath?.localNetworkAvailable == true, let endpoint else { return nil }
        if case .failed(let failedAt) = state, failedAt.duration(to: now) < Self.lanRetryDelay { return nil }
        return endpoint
    }

    var verifiedLAN: GatewayLANEndpoint? {
        guard networkPath?.localNetworkAvailable == true, case .verified = state else { return nil }
        return endpoint
    }

    var relayCandidate: GatewayRelayEndpoint? {
        usesLearnedRoutes && endpoint != nil ? relay : nil
    }

    func connectionRoutes(at now: ContinuousClock.Instant) -> [GatewayRoute] {
        (lanCandidate(at: now).map { [.lan($0)] } ?? []) + fallbackRoutes(at: now)
    }

    func requestRoutes(at now: ContinuousClock.Instant) -> [GatewayRoute] {
        let fallbacks = fallbackRoutes(at: now)
        return (verifiedLAN.map { [.lan($0)] } ?? []) + fallbacks.filter { $0 == lastConnectedFallback }
            + fallbacks.filter { $0 != lastConnectedFallback }
    }

    func configuredIsBackingOff(at now: ContinuousClock.Instant) -> Bool {
        configuredFailures.isBackingOff(at: now)
    }

    private func fallbackRoutes(at now: ContinuousClock.Instant) -> [GatewayRoute] {
        guard let relay = relayCandidate else { return [.configured] }
        let prefersRelay = configuredFailures.isBackingOff(at: now) && !relayFailures.isBackingOff(at: now)
        return prefersRelay ? [.relay(relay), .configured] : [.configured, .relay(relay)]
    }

    mutating func learn(_ endpoint: GatewayLANEndpoint?) -> Bool {
        guard endpoint != self.endpoint else { return false }
        self.endpoint = endpoint
        state = .untested
        return true
    }

    mutating func learnRelay(_ relay: GatewayRelayEndpoint?) -> Bool {
        guard relay != self.relay else { return false }
        self.relay = relay
        relayFailures = PathFailures()
        return true
    }

    @discardableResult
    mutating func networkPathChanged(_ path: GatewayNetworkPath) -> Bool {
        guard networkPath != path else { return false }
        networkPath = path
        state = .untested
        configuredFailures = PathFailures()
        relayFailures = PathFailures()
        return true
    }

    mutating func connected(_ route: GatewayRoute) {
        if case .lan = route { lastConnectedFallback = nil } else { lastConnectedFallback = route }
    }

    @discardableResult
    mutating func succeeded(_ route: GatewayRoute) -> Bool {
        let penalized: Bool
        switch route {
        case .lan(let endpoint):
            guard endpoint == self.endpoint else { return false }
            penalized = if case .failed = state { true } else { false }
            state = .verified
        case .configured:
            penalized = !configuredFailures.isEmpty
            configuredFailures = PathFailures()
        case .relay(let relay):
            guard relay == self.relay else { return false }
            penalized = !relayFailures.isEmpty
            relayFailures = PathFailures()
        }
        return penalized
    }

    mutating func failed(_ route: GatewayRoute, at now: ContinuousClock.Instant) {
        if route == lastConnectedFallback { lastConnectedFallback = nil }
        switch route {
        case .lan(let endpoint): if endpoint == self.endpoint { state = .failed(now) }
        case .configured: configuredFailures.record(at: now)
        case .relay(let relay): if relay == self.relay { relayFailures.record(at: now) }
        }
    }
}

actor GatewayRoutes {
    private static let lanTimeout: TimeInterval = 2
    private static let configuredTimeout: TimeInterval = 10
    private static let configuredTimeoutBeforeRelay: TimeInterval = 5
    private static let relayTimeout: TimeInterval = 10
    private static let lanHeadStart = Duration.milliseconds(500)
    private static let fallbackHeadStart = Duration.seconds(1)
    private static let relearnInterval = Duration.seconds(600)

    private let lanSession: URLSession
    private let lanDownloadSession: URLSession
    private let configuredDownloadSession: URLSession
    private let host: GatewayHostConfiguration
    private let endpointFile: URL
    private let relayStorage: any GatewayCredentialStorage
    private let trust: GatewayLANTrust
    private let forcesRelay: Bool
    private let localNetworkUpdates: AsyncStream<GatewayNetworkPath>.Continuation
    private let logger = AppLogger(category: "GatewayRoutes")
    private var policy: GatewayRoutePolicy
    private var relayLoaded = false
    private var relayUnpersisted = false
    private var pathChangedAt = ContinuousClock.now
    private var relaySessions: RelaySessions?
    private var replacedRelaySessions: [URLSession] = []
    private var learning: Task<Void, Never>?
    private var learnedAt: ContinuousClock.Instant?
    private var probing: Task<Bool, Never>?
    private var isRetired = false
    private var networkSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    private struct RelaySessions {
        let relay: GatewayRelayEndpoint
        let standard: URLSession
        let download: URLSession
    }

    init(host: GatewayHostConfiguration, directory: URL, relayStorage: any GatewayCredentialStorage,
         policy sharedPolicy: SharedGatewayPolicy,
         observeLocalNetwork: (AsyncStream<GatewayNetworkPath>.Continuation) -> Void) {
        let endpointFile = directory.appending(path: "lan-endpoint.json")
        let endpoint = Self.loadEndpoint(from: endpointFile, learnedFrom: host.connectionSummary)
        let trust = GatewayLANTrust(pin: endpoint?.spkiSHA256)
        let lan = AppStorageScope.current.networkConfiguration(.ephemeral)
        GatewayRoute.keepOnLocalNetwork(lan)
        lanSession = URLSession(configuration: lan, delegate: trust, delegateQueue: nil)
        lanDownloadSession = URLSession(configuration: Self.downloading(lan), delegate: trust, delegateQueue: nil)
        configuredDownloadSession = URLSession(configuration: Self.downloading(AppStorageScope.current.networkConfiguration(.ephemeral)))
        self.host = host
        self.endpointFile = endpointFile
        self.relayStorage = relayStorage
        self.trust = trust
        forcesRelay = sharedPolicy.forcesRelay
        policy = GatewayRoutePolicy(endpoint: endpoint, usesLearnedRoutes: sharedPolicy.usesLearnedRoutes)
        let (updates, continuation) = AsyncStream.makeStream(of: GatewayNetworkPath.self, bufferingPolicy: .bufferingNewest(1))
        localNetworkUpdates = continuation
        observeLocalNetwork(continuation)
        Task { [weak self] in
            for await path in updates { await self?.networkPathChanged(path) }
        }
    }

    deinit {
        localNetworkUpdates.finish()
        lanSession.invalidateAndCancel()
        lanDownloadSession.invalidateAndCancel()
        configuredDownloadSession.invalidateAndCancel()
        for session in [relaySessions?.standard, relaySessions?.download].compactMap({ $0 }) + replacedRelaySessions {
            session.invalidateAndCancel()
        }
    }

    private static func downloading(_ base: URLSessionConfiguration) -> URLSessionConfiguration {
        let configuration = base.copy() as? URLSessionConfiguration ?? base
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return configuration
    }

    static func observeLocalNetwork(_ updates: AsyncStream<GatewayNetworkPath>.Continuation) {
        let monitor = NWPathMonitor()
        let previousPath = Mutex<(path: NWPath, identity: UUID)?>(nil)
        monitor.pathUpdateHandler = { path in
            let identity = previousPath.withLock { previous in
                if let previous, previous.path == path { return previous.identity }
                let identity = UUID()
                previous = (path, identity)
                return identity
            }
            updates.yield(GatewayNetworkPath(identity: identity,
                localNetworkAvailable: path.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }))
        }
        updates.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "RemoteCoder.GatewayRoutes.localNetwork"))
    }

    func connectionRoutes() -> [GatewayRoute] {
        guard !isRetired else { return [.configured] }
        loadRelayIfNeeded()
        return restricted(policy.connectionRoutes(at: .now))
    }

    func preferredRoute() -> GatewayRoute {
        requestRoutes().first ?? .configured
    }

    nonisolated func acceptsServerTrust(_ serverTrust: SecTrust) -> Bool {
        trust.accepts(serverTrust)
    }

    nonisolated static func headStart(for route: GatewayRoute) -> Duration {
        switch route {
        case .lan: lanHeadStart
        case .configured, .relay: fallbackHeadStart
        }
    }

    func preferredRoutes(over current: GatewayRoute) -> [GatewayRoute] {
        Array(connectionRoutes().prefix { $0 != current })
    }

    func timeout(for route: GatewayRoute) -> TimeInterval {
        switch route {
        case .lan: Self.lanTimeout
        case .configured: policy.relayCandidate == nil ? Self.configuredTimeout : Self.configuredTimeoutBeforeRelay
        case .relay: Self.relayTimeout
        }
    }

    func webSocketTask(with request: URLRequest, over route: GatewayRoute) throws -> URLSessionWebSocketTask {
        guard let session = session(for: route, traffic: .read) else { throw URLError(.cancelled) }
        return session.webSocketTask(with: request)
    }

    func connected(over route: GatewayRoute, startedAt: ContinuousClock.Instant, afterFailing failedRoutes: [GatewayRoute]) {
        guard !isRetired else { return }
        if startedAt >= pathChangedAt {
            for failed in failedRoutes { policy.failed(failed, at: .now) }
        }
        policy.connected(route)
        succeeded(route)
        learnIfDue(over: route)
    }

    func moved(to route: GatewayRoute, startedAt: ContinuousClock.Instant, afterFailing failedRoutes: [GatewayRoute]) {
        guard !isRetired else { return }
        if startedAt >= pathChangedAt {
            for failed in failedRoutes { policy.failed(failed, at: .now) }
        }
        policy.connected(route)
        if case .lan = route { succeeded(route) }
        learnIfDue(over: route)
    }

    @discardableResult
    func failed(_ route: GatewayRoute, error: any Error, startedAt: ContinuousClock.Instant) -> Bool {
        guard !isRetired, startedAt >= pathChangedAt else { return false }
        let isLAN = if case .lan = route { true } else { false }
        guard isLAN || GatewayRoute.isPathFailure(error) else { return false }
        policy.failed(route, at: .now)
        logger.notice("Gateway route \(Self.describe(route)) failed: \(error.localizedDescription)")
        if isLAN {
            learnedAt = nil
            learnIfDue(over: .configured)
        }
        return true
    }

    func send<Response: Sendable>(_ request: URLRequest, traffic: GatewayTraffic,
                                  _ exchange: @Sendable (URLRequest, URLSession) async throws -> Response) async throws -> Response {
        var failure: URLError?
        for route in requestRoutes() {
            guard let url = request.url.flatMap(route.url(replacingAddressOf:)) else { continue }
            var routed = request
            routed.url = url
            if traffic == .read { routed.timeoutInterval = timeout(for: route) }
            guard let session = session(for: route, traffic: traffic) else { continue }
            let started = ContinuousClock.now
            do {
                let response = try await exchange(routed, session)
                succeeded(route)
                return response
            } catch let error as URLError where !Task.isCancelled {
                failed(route, error: error, startedAt: started)
                if traffic == .mutation, !GatewayRoute.neverReachedGateway(error) { throw error }
                if route == .configured || failure == nil { failure = error }
            }
        }
        throw failure ?? URLError(.cannotConnectToHost)
    }

    func preferredRouteResponds(over current: GatewayRoute) async -> Bool {
        await learning?.value
        guard !Task.isCancelled else { return false }
        if forcesRelay, policy.relayCandidate != nil { return current.kind != .relay }
        switch current {
        case .lan:
            return false
        case .configured:
            return await probeLAN()
        case .relay:
            if await probeLAN() { return true }
            guard !policy.configuredIsBackingOff(at: .now) else { return false }
            return await responds(over: .configured)
        }
    }

    func probeRelay() async -> Bool? {
        loadRelayIfNeeded()
        guard !isRetired, let relay = policy.relayCandidate else { return nil }
        return await responds(over: .relay(relay))
    }

    func retire() {
        isRetired = true
        learning?.cancel()
        probing?.cancel()
        localNetworkUpdates.finish()
        for continuation in networkSubscribers.values { continuation.finish() }
        networkSubscribers.removeAll()
    }

    func networkPathChanges() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        networkSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeNetworkSubscriber(id) } }
        return stream
    }

    func lanCandidate() -> GatewayLANEndpoint? {
        isRetired ? nil : policy.lanCandidate(at: .now)
    }

    private func removeNetworkSubscriber(_ id: UUID) {
        networkSubscribers.removeValue(forKey: id)
    }

    private func networkPathChanged(_ path: GatewayNetworkPath) {
        guard !isRetired, policy.networkPathChanged(path) else { return }
        pathChangedAt = .now
        logger.notice("Route penalties reset: the network path changed localNetwork=\(path.localNetworkAvailable)")
        for continuation in networkSubscribers.values { continuation.yield() }
    }

    private func succeeded(_ route: GatewayRoute) {
        guard !isRetired else { return }
        if policy.succeeded(route) {
            logger.notice("Route penalties reset: \(Self.describe(route)) succeeded")
        }
    }

    private func requestRoutes() -> [GatewayRoute] {
        guard !isRetired else { return [.configured] }
        loadRelayIfNeeded()
        return restricted(policy.requestRoutes(at: .now))
    }

    private func restricted(_ routes: [GatewayRoute]) -> [GatewayRoute] {
        guard forcesRelay, policy.relayCandidate != nil else { return routes }
        return routes.filter { $0.kind == .relay }
    }

    private func session(for route: GatewayRoute, traffic: GatewayTraffic) -> URLSession? {
        switch route {
        case .lan: return traffic == .download ? lanDownloadSession : lanSession
        case .configured: return traffic == .download ? configuredDownloadSession : AppStorageScope.networkSession
        case .relay(let relay):
            guard relay == policy.relayCandidate else { return nil }
            let sessions = relaySessions(for: relay)
            return traffic == .download ? sessions.download : sessions.standard
        }
    }

    private func relaySessions(for relay: GatewayRelayEndpoint) -> RelaySessions {
        if let relaySessions, relaySessions.relay == relay { return relaySessions }
        if let previous = relaySessions { replacedRelaySessions += [previous.standard, previous.download] }
        let configuration = AppStorageScope.current.networkConfiguration(.ephemeral)
        GatewayRoute.relay(relay).configure(configuration)
        let sessions = RelaySessions(relay: relay,
            standard: URLSession(configuration: configuration, delegate: trust, delegateQueue: nil),
            download: URLSession(configuration: Self.downloading(configuration), delegate: trust, delegateQueue: nil))
        relaySessions = sessions
        return sessions
    }

    private func probeLAN() async -> Bool {
        if let probing { return await probing.value }
        guard let endpoint = lanCandidate() else { return false }
        let task = Task { await self.probe(endpoint) }
        probing = task
        defer { probing = nil }
        return await task.value
    }

    private func probe(_ endpoint: GatewayLANEndpoint) async -> Bool {
        let started = ContinuousClock.now
        do {
            let reported = try await health(over: .lan(endpoint))
            guard !isRetired else { return false }
            learnedAt = .now
            succeeded(.lan(endpoint))
            apply(reported)
            return reported == endpoint && started >= pathChangedAt
        } catch {
            failed(.lan(endpoint), error: error, startedAt: started)
            return false
        }
    }

    private func responds(over route: GatewayRoute) async -> Bool {
        let started = ContinuousClock.now
        do {
            _ = try await read(path: "version", over: route)
            return !isRetired && started >= pathChangedAt
        } catch {
            failed(route, error: error, startedAt: started)
            return false
        }
    }

    private func learnIfDue(over route: GatewayRoute) {
        guard policy.usesLearnedRoutes, learning == nil,
              learnedAt.map({ $0.duration(to: .now) >= Self.relearnInterval }) ?? true else { return }
        learning = Task { await self.learn(over: route) }
    }

    private func learn(over route: GatewayRoute) async {
        defer { learning = nil }
        do {
            let reported = try await health(over: route)
            guard !isRetired else { return }
            learnedAt = .now
            apply(reported)
        } catch {
            guard !isRetired else { return }
            logger.notice("Could not read the LAN route from /health: \(error.localizedDescription)")
        }
        do {
            let relay = try await relay(over: route)
            guard !isRetired else { return }
            applyRelay(relay)
        } catch {
            guard !isRetired else { return }
            logger.notice("Could not read the relay route: \(error.localizedDescription)")
        }
    }

    private func apply(_ endpoint: GatewayLANEndpoint?) {
        guard policy.learn(endpoint) else { return }
        trust.replacePin(endpoint?.spkiSHA256)
        persist(endpoint)
        if let endpoint {
            logger.notice("Learned LAN route \(endpoint.host):\(endpoint.port)")
        } else {
            logger.notice("The gateway reports no LAN route")
        }
    }

    private func applyRelay(_ relay: GatewayRelayEndpoint?) {
        let cacheUnread = !relayLoaded
        relayLoaded = true
        let changed = policy.learnRelay(relay)
        if changed, !cacheUnread { logger.notice("Route penalties reset: the relay route changed") }
        guard changed || relayUnpersisted || cacheUnread else { return }
        do {
            try relayStorage.write(JSONEncoder().encode(CachedRelay(learnedFrom: host.connectionSummary, relay: relay)))
            relayUnpersisted = false
        } catch {
            relayUnpersisted = true
            logger.error("Could not keep the relay route: \(error.localizedDescription)")
        }
        guard changed else { return }
        if let relay {
            logger.notice("Learned relay route \(relay.targetHost):\(relay.targetPort) through \(relay.proxyHost)")
        } else {
            logger.notice("The gateway reports no relay route")
        }
    }

    private func loadRelayIfNeeded() {
        guard policy.usesLearnedRoutes, !relayLoaded else { return }
        do {
            let data = try relayStorage.read()
            relayLoaded = true
            guard let data else { return }
            let cached = try JSONDecoder().decode(CachedRelay.self, from: data)
            if cached.learnedFrom == host.connectionSummary { _ = policy.learnRelay(cached.relay) }
        } catch let error as GatewayCredentialFailure {
            logger.error("The relay route is unavailable: \(error.localizedDescription)")
        } catch {
            logger.error("Ignoring an unreadable relay route: \(error.localizedDescription)")
        }
    }

    private func persist(_ endpoint: GatewayLANEndpoint?) {
        do {
            if let endpoint {
                try FileManager.default.createDirectory(at: endpointFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(CachedEndpoint(learnedFrom: host.connectionSummary, endpoint: endpoint))
                    .write(to: endpointFile, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: endpointFile)
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            logger.error("Could not persist the LAN route: \(error.localizedDescription)")
        }
    }

    private struct CachedEndpoint: Codable {
        let learnedFrom: String
        let endpoint: GatewayLANEndpoint
    }

    private struct CachedRelay: Codable {
        let learnedFrom: String
        let relay: GatewayRelayEndpoint?
    }

    private struct Health: Decodable {
        let lanEndpoint: GatewayLANEndpoint?
    }

    private struct RouteUnavailable: LocalizedError {
        let path: String
        let status: Int?
        var errorDescription: String? { "The gateway /\(path) read answered \(status.map { "HTTP \($0)" } ?? "without HTTP")." }
    }

    private func health(over route: GatewayRoute) async throws -> GatewayLANEndpoint? {
        let data = try await read(path: "health", over: route)
        return try JSONDecoder().decode(Health.self, from: data).lanEndpoint
    }

    private func relay(over route: GatewayRoute) async throws -> GatewayRelayEndpoint? {
        let exchange = try await fetch(path: "relay", over: route)
        if (exchange.1 as? HTTPURLResponse)?.statusCode == 404 { return nil }
        return try JSONDecoder().decode(GatewayRelayEndpoint.self, from: Self.requireOK(exchange, path: "relay"))
    }

    func version() async throws -> BuildIdentity {
        guard let url = host.gatewayHTTPBaseURL()?.appending(path: "version") else { throw GatewayClient.ClientError.invalidURL }
        let data = try await send(readRequest(url), traffic: .read) { request, session in
            try await Self.requireOK(session.data(for: request), path: "version")
        }
        return try JSONDecoder().decode(BuildIdentity.self, from: data)
    }

    func identity() async throws -> GatewayIdentity {
        guard let url = host.gatewayHTTPBaseURL()?.appending(path: "health") else { throw GatewayClient.ClientError.invalidURL }
        let data = try await send(readRequest(url), traffic: .read) { request, session in
            var request = request
            request.timeoutInterval = 10
            return try await Self.requireOK(session.data(for: request), path: "health")
        }
        return try JSONDecoder().decode(GatewayIdentity.self, from: data)
    }

    private func read(path: String, over route: GatewayRoute) async throws -> Data {
        try await Self.requireOK(fetch(path: path, over: route), path: path)
    }

    private func fetch(path: String, over route: GatewayRoute) async throws -> (Data, URLResponse) {
        guard let url = host.gatewayHTTPBaseURL()?.appending(path: path), let routed = route.url(replacingAddressOf: url) else {
            throw GatewayClient.ClientError.invalidURL
        }
        guard let session = session(for: route, traffic: .read) else { throw URLError(.cancelled) }
        var request = readRequest(routed)
        request.timeoutInterval = timeout(for: route)
        return try await session.data(for: request)
    }

    private func readRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(host.authToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func requireOK(_ exchange: (Data, URLResponse), path: String) throws -> Data {
        let status = (exchange.1 as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw RouteUnavailable(path: path, status: status) }
        return exchange.0
    }

    private static func describe(_ route: GatewayRoute) -> String {
        switch route {
        case .lan(let endpoint): "LAN \(endpoint.host):\(endpoint.port)"
        case .configured: "configured"
        case .relay(let relay): "relay \(relay.targetHost):\(relay.targetPort)"
        }
    }

    private static func loadEndpoint(from file: URL, learnedFrom address: String) -> GatewayLANEndpoint? {
        let logger = AppLogger(category: "GatewayRoutes")
        do {
            let cached = try JSONDecoder().decode(CachedEndpoint.self, from: Data(contentsOf: file))
            return cached.learnedFrom == address ? cached.endpoint : nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            logger.error("Ignoring an unreadable LAN route cache: \(error.localizedDescription)")
            return nil
        }
    }
}
