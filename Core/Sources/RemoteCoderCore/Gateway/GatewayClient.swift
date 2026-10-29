import Foundation
import OSLog
import Synchronization

struct CodexGatewayNotification: Sendable {
    let method: String
    let params: JSONValue?
    let server: ServerNotification
    let receivedAt: Date?
    let sequence: UInt64?
    let receipt: GatewayWireReceipt?

    init(method: String, params: JSONValue?, server: ServerNotification, receivedAt: Date? = nil, sequence: UInt64? = nil,
         receipt: GatewayWireReceipt? = nil) {
        self.method = method
        self.params = params
        self.server = server
        self.receivedAt = receivedAt
        self.sequence = sequence
        self.receipt = receipt
    }
}

struct GatewayWireReceipt: Sendable, Equatable {
    let connection: UUID
    let sequence: UInt64
}

nonisolated enum GatewayTransportLimits {
    // Gateway enforces 32 MiB inbound websocket frames; match that so history reads
    // that contain base64 image inputs (thread/read includeTurns) don't get dropped
    // by URLSessionWebSocketTask's default max message size.
    static let maximumMessageSizeBytes = 32 * 1024 * 1024
    static let largeFrameThresholdBytes = 16 * 1024
    static let largeFramePayloadBytesPerSecond = 8_000
}

actor GatewayClient: CodexHistoryGateway, ConversationContentSubscriptions {
    struct Config: Sendable {
        let url: URL
        let authToken: String
        /// How this gateway is named back to the user when it cannot be reached.
        let hostLabel: String
    }

    enum ClientError: LocalizedError {
        case notConnected
        case invalidURL
        case invalidMessage
        case invalidResponse
        case serverError(message: String, code: Int?)
        case connectionClosed
        case retired
        case historyCapacity(actualBytes: Int, limitBytes: Int)
        case subscriptionCapacity(actual: Int, limit: Int)
        case invalidSubscriptionThreadID
        case requestTimedOut(method: String)
        case connectionFailed(host: String, reason: String)
        case gatewayRestarting
        case gatewayNotReady(host: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The gateway sent an unreadable message. Reconnecting."
            case .retired:
                return "This gateway connection has been retired."
            case .notConnected:
                return "Codex gateway is not connected."
            case .invalidURL:
                return "Invalid Codex gateway URL."
            case .invalidMessage:
                return "Received an invalid response from the Codex gateway."
            case .serverError(let message, let code):
                if let code {
                    return "Codex gateway error (\(code)): \(message)"
                }
                return "Codex gateway error: \(message)"
            case .connectionClosed:
                return "Codex gateway connection closed."
            case .historyCapacity(let actual, let limit):
                return "History contains an item too large to transfer (\(actual) bytes; limit \(limit)). Load a different history page."
            case .subscriptionCapacity(let actual, let limit):
                return "Too many Claude conversations are retained (\(actual); limit \(limit)). Close a conversation to enable scoped live content."
            case .invalidSubscriptionThreadID:
                return "A retained Claude conversation has an invalid thread ID."
            case .requestTimedOut(let method):
                return "Codex gateway request timed out (\(method))."
            case .connectionFailed(let host, let reason):
                return "Could not connect to \(host). \(reason)"
            case .gatewayNotReady(let host, let reason):
                return "\(host) closed the connection: \(reason)"
            case .gatewayRestarting:
                return "Codex gateway is restarting."
            }
        }
    }

    enum ContentSubscriptionState: Sendable {
        case unknown
        case subscribed(Set<String>)
        case unsupported(code: Int)
        case failed(ClientError)
    }

    struct Timeouts: Sendable {
        var request = Duration.seconds(15)
        // Starting, resuming, and forking can include shell snapshot creation and MCP startup.
        // Keep ordinary RPCs fail-fast without abandoning a thread that Codex is still creating.
        var threadSetup = Duration.seconds(150)
        var history = Duration.seconds(60)
        var commandExec = Duration.seconds(120)
        var realtimeSetup = Duration.seconds(45)
        var restartWindow = Duration.seconds(120)
    }

    private let config: Config
    private let routes: GatewayRoutes?
    private let deviceTools: DeviceToolConnection?
    private var deviceResultTasks: [UUID: Task<Void, Never>] = [:]
    let timeouts: Timeouts
    private let logger = AppLogger(category: "CodexGateway")
    private let debugLogger = Logger(subsystem: AppLogger.subsystem, category: "CodexGateway")

    private var session: URLSession = URLSession(configuration: AppStorageScope.current.networkConfiguration(.default))
    private var webSocket: URLSessionWebSocketTask?
    private var route: GatewayRoute?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var pendingPingID: UUID?
    private var standby: Task<Void, Never>?
    private let holdsConnection: @Sendable @MainActor () -> Bool
    private var announced = GatewayConnectivity.disconnected
    private(set) var disconnections: UInt64 = 0
    private var receiveDeadline = GatewayReceiveDeadline(now: .now)
    private var livenessSuspended = false
    private var connectionGeneration = UUID()
    private var wireSequence: UInt64 = 0
    private var didInitialize: Bool = false
    private var supportsRequestCancellation = false
    private var connectionInFlight: Task<Void, Error>?
    private var reconnect = GatewayReconnectPolicy()
    private var lastConnectionFailure: (any Error)?
    private var reconnectWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var expeditedBy: ReconnectTrigger?
    private var initializeInFlight: Task<Void, Error>?
    private var contentSubscriptionRevision: UInt64 = 0
    private var contentSubscriptionThreads: Set<String> = []
    private var contentSubscriptionFailure: ClientError?
    private(set) var contentSubscriptionState = ContentSubscriptionState.unknown
    private var contentSubscriptionSync: (id: UUID, task: Task<Void, Error>)?

    private var pending = RequestTable()
    private var observationCleanupTasks: [String: Task<Void, Never>] = [:]
    private var failedObservationCleanup: [String: UUID] = [:]
    private var hub = NotificationHub()

    private var isRetired = false
    private var restartObservedAt: ContinuousClock.Instant?
    private static let restartingCloseCode = 4012

    var connectionIdentity: UUID? { isConnected ? connectionGeneration : nil }

    var isConnected: Bool {
        didInitialize && webSocket != nil
    }

    var connectivity: GatewayConnectivity {
        if isConnected, let route { .connected(route.kind) } else if isRestarting { .restarting } else if lastConnectionFailure != nil { .unreachable } else { .disconnected }
    }

    private var isRestarting: Bool {
        restartObservedAt.map { .now - $0 < timeouts.restartWindow } ?? false
    }

    private func announceUnavailability() {
        guard !isConnected, connectivity != announced else { return }
        announced = connectivity
        let event: GatewayConnectionEvent = switch announced {
        case .restarting: .restarting
        case .unreachable: .unreachable
        case .connected, .disconnected: .disconnected
        }
        hub.emit(event)
    }

    private func observeRestart(closing task: URLSessionWebSocketTask) -> Bool {
        guard task.closeCode.rawValue == Self.restartingCloseCode else { return false }
        restartObservedAt = restartObservedAt ?? .now
        return isRestarting
    }

    func connectionEvents() -> AsyncStream<GatewayConnectionEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            guard !isRetired else { continuation.finish(); return }
            let id = hub.addEventSubscriber(continuation)
            continuation.onTermination = { @Sendable [self] _ in
                Task {
                    await removeEventSubscriber(id: id)
                }
            }
        }
    }

    init(config: Config, routes: GatewayRoutes?, timeouts: Timeouts = Timeouts(), deviceTools: DeviceToolConnection? = nil,
         holdsConnection: @escaping @Sendable @MainActor () -> Bool = { false }) {
        self.config = config
        self.routes = routes
        self.timeouts = timeouts
        self.deviceTools = deviceTools
        self.holdsConnection = holdsConnection
    }

    init(host: GatewayHostConfiguration, routes: GatewayRoutes?, timeouts: Timeouts = Timeouts(),
         deviceTools: DeviceToolHost? = nil, holdsConnection: @escaping @Sendable @MainActor () -> Bool = { false }) throws {
        guard let url = host.gatewayWebSocketURL() else { throw ClientError.invalidURL }
        let binding: DeviceToolConnection?
        if let deviceTools, let routes {
            binding = DeviceToolConnection(host: deviceTools, uploadHost: host, uploader: GatewayUploadClient(routes: routes))
        } else {
            precondition(deviceTools == nil)
            binding = nil
        }
        self.init(config: Config(url: url, authToken: host.authToken, hostLabel: host.errorLabel), routes: routes,
                  timeouts: timeouts, deviceTools: binding, holdsConnection: holdsConnection)
    }

    func notifications() -> AsyncStream<CodexGatewayNotification> {
        AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            guard !isRetired else { continuation.finish(); return }
            let id = hub.add(continuation)
            continuation.onTermination = { @Sendable [self] _ in
                Task {
                    await removeNotificationContinuation(id: id)
                }
            }
        }
    }

    private enum ReconnectTrigger: String {
        case demand
        case backoff
        case foreground
        case networkPath
    }

    func connectIfNeeded() async throws {
        try await connect(waitingAtMost: timeouts.request)
    }

    func connectWhenPermitted() async throws {
        try await connect(waitingAtMost: nil)
    }

    private func connect(waitingAtMost budget: Duration?) async throws {
        guard !isRetired else { throw ClientError.retired }
        try Task.checkCancellation()
        let deadline = budget.map { ContinuousClock.now + $0 }
        while connectionInFlight == nil, let notBefore = reconnect.notBefore, notBefore > .now {
            if let deadline, deadline < notBefore { throw lastConnectionFailure ?? ClientError.connectionClosed }
            await waitForReconnect(until: notBefore)
            guard !isRetired else { throw ClientError.retired }
            try Task.checkCancellation()
        }
        if didInitialize, webSocket?.state == .running {
            try await synchronizeContentSubscriptions()
            return
        }

        if let connectionInFlight {
            try await connectionInFlight.value
            try await synchronizeContentSubscriptions()
            return
        }

        let trigger = expeditedBy ?? (reconnect.failures > 0 ? .backoff : .demand)
        expeditedBy = nil
        let task = Task(name: "Codex gateway connection") { [self] in
            try await establishConnection(trigger: trigger)
        }
        connectionInFlight = task
        do {
            try await task.value
            if connectionInFlight == task { connectionInFlight = nil }
            try await synchronizeContentSubscriptions()
        } catch {
            if connectionInFlight == task { connectionInFlight = nil }
            throw error
        }
    }

    private func establishConnection(trigger: ReconnectTrigger) async throws {
        let started = ContinuousClock.now
        let step = reconnect.failures
        let candidates = await routes?.connectionRoutes() ?? [.configured]
        do {
            let route = try await connectOverAvailableRoute(candidates, startedAt: started)
            logger.notice("Gateway connection attempt trigger=\(trigger.rawValue) step=\(step) routes=\(candidates.count) elapsedMs=\(started.duration(to: .now) / .milliseconds(1)) outcome=connected route=\(String(describing: route))")
        } catch {
            if !Task.isCancelled { await disconnectTransport(reason: error) }
            let failure: any Error = if let error = error as? URLError {
                // Only transport failures are reattributed: a dead host and a wrong
                // active host both surface as a bare "Could not connect to the
                // server.", which names neither. Protocol errors already say what
                // they are and pass through untouched.
                ClientError.connectionFailed(
                    host: config.hostLabel,
                    reason: error.localizedDescription
                )
            } else {
                error
            }
            guard !Task.isCancelled, !isRetired, !(error is CancellationError) else { throw failure }
            lastConnectionFailure = failure
            announceUnavailability()
            let delay = reconnect.failed(at: .now, restartingSince: restartObservedAt)
            logger.notice("Gateway connection attempt trigger=\(trigger.rawValue) step=\(step) routes=\(candidates.count) elapsedMs=\(started.duration(to: .now) / .milliseconds(1)) outcome=failed nextDelayMs=\(delay / .milliseconds(1)) error=\(failure.localizedDescription)")
            throw failure
        }
    }

    private func connectOverAvailableRoute(_ candidates: [GatewayRoute], startedAt started: ContinuousClock.Instant)
        async throws -> GatewayRoute.Kind {
        guard !isRetired else { throw ClientError.retired }
        try Task.checkCancellation()
        if let webSocket {
            logger.notice("WebSocket stale (state=\(webSocket.state.rawValue)), reconnecting")
            await disconnectTransport()
        }

        guard config.url.scheme == "ws" || config.url.scheme == "wss" else {
            throw ClientError.invalidURL
        }

        let race = try await race(candidates)
        try await install(race.socket, over: race.route)
        await routes?.connected(over: race.route, startedAt: started, afterFailing: race.unrecorded)
        return race.route.kind
    }

    private func waitForReconnect(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(until: deadline)) != nil else { return }
            await self?.wakeReconnectWaiter(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { reconnectWaiters[id] = $0 }
        } onCancel: {
            Task { [weak self] in await self?.wakeReconnectWaiter(id) }
        }
        timer.cancel()
    }

    private func wakeReconnectWaiter(_ id: UUID) {
        reconnectWaiters.removeValue(forKey: id)?.resume()
    }

    private func wakeReconnectWaiters() {
        let waiters = reconnectWaiters.values
        reconnectWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func expediteReconnect(_ trigger: ReconnectTrigger) {
        guard !isConnected, connectionInFlight == nil, reconnect.expedite(at: .now) else { return }
        expeditedBy = trigger
        logger.notice("Gateway reconnect expedited trigger=\(trigger.rawValue)")
        wakeReconnectWaiters()
    }

    private struct GatewaySocket: Sendable {
        let task: URLSessionWebSocketTask
        let first: URLSessionWebSocketTask.Message
    }

    private struct RaceWinner {
        let route: GatewayRoute
        let socket: GatewaySocket
        let unrecorded: [GatewayRoute]
    }

    private func race(_ candidates: [GatewayRoute]) async throws -> RaceWinner {
        let started = ContinuousClock.now
        let outcome = await GatewayRouteRace(
            candidates: candidates.map { ($0, GatewayRoutes.headStart(for: $0)) },
            attempt: { [self] in try await handshake($0) },
            discard: { $0.task.cancel(with: .goingAway, reason: nil) }
        ).run()
        if isRetired || Task.isCancelled {
            outcome.winner?.connection.task.cancel(with: .goingAway, reason: nil)
            throw isRetired ? ClientError.retired : CancellationError()
        }
        guard let winner = outcome.winner else {
            let failure = outcome.failures.first { $0.route == .configured }?.error ?? outcome.failures.first?.error
            throw isRestarting ? ClientError.gatewayRestarting : failure ?? ClientError.connectionClosed
        }
        var unrecorded: [GatewayRoute] = []
        for (route, error) in outcome.failures {
            let blamesRoute = switch error {
            case ClientError.gatewayNotReady, ClientError.gatewayRestarting: false
            default: !isRestarting
            }
            if blamesRoute, await routes?.failed(route, error: error, startedAt: started) == false { unrecorded.append(route) }
        }
        return RaceWinner(route: winner.route, socket: winner.connection, unrecorded: unrecorded)
    }

    private func handshake(_ route: GatewayRoute) async throws -> GatewaySocket {
        guard !isRetired else { throw ClientError.retired }
        try Task.checkCancellation()
        guard let url = route.url(replacingAddressOf: config.url) else { throw ClientError.invalidURL }
        var request = URLRequest(url: url)
        // The default 60 s handshake timeout let a zombie socket (accepted,
        // then torn down by a network bounce) hold reconnects hostage for
        // over a minute; the gateway answers a healthy handshake in well
        // under a second even over Tailscale.
        let timeout = await routes?.timeout(for: route) ?? 10
        request.timeoutInterval = timeout
        request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
        let task: URLSessionWebSocketTask
        if route == .configured {
            task = session.webSocketTask(with: request)
        } else if let routes {
            task = try await routes.webSocketTask(with: request, over: route)
        } else {
            throw ClientError.invalidURL
        }
        logger.notice("Connecting to gateway at \(url.absoluteString)")
        task.maximumMessageSize = GatewayTransportLimits.maximumMessageSizeBytes
        task.resume()
        let readyTimeout = timeouts.request
        do {
            let first = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask { try await Self.firstMessage(from: task) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    guard Self.upgraded(task) else { throw URLError(.timedOut) }
                    try await Task.sleep(for: readyTimeout)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw URLError(.timedOut) }
                return first
            }
            return GatewaySocket(task: task, first: first)
        } catch {
            let closedByGateway = task.closeCode != .invalid
            let restarting = observeRestart(closing: task)
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
            task.cancel(with: .goingAway, reason: nil)
            guard closedByGateway, !(error is CancellationError) else { throw error }
            throw restarting ? ClientError.gatewayRestarting
                : ClientError.gatewayNotReady(host: config.hostLabel, reason: reason ?? error.localizedDescription)
        }
    }

    private static func upgraded(_ task: URLSessionWebSocketTask) -> Bool {
        (task.response as? HTTPURLResponse)?.statusCode == 101
    }

    private static func firstMessage(from task: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        let waiter = Mutex<CheckedContinuation<URLSessionWebSocketTask.Message, any Error>?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.withLock { $0 = continuation }
                if Task.isCancelled { waiter.withLock { $0.take() }?.resume(throwing: CancellationError()) }
                task.receive { result in waiter.withLock { $0.take() }?.resume(with: result) }
            }
        } onCancel: {
            waiter.withLock { $0.take() }?.resume(throwing: CancellationError())
        }
    }

    private func install(_ socket: GatewaySocket, over route: GatewayRoute) async throws {
        let task = socket.task
        guard !isRetired, !Task.isCancelled, webSocket == nil else {
            task.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled { throw CancellationError() }
            throw isRetired ? ClientError.retired : ClientError.connectionClosed
        }
        webSocket = task
        self.route = route
        connectionGeneration = UUID()
        receiveDeadline = GatewayReceiveDeadline(now: .now)
        wireSequence = 0
        let generation = connectionGeneration

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: task, generation: generation, first: socket.first)
        }

        didInitialize = false
        supportsRequestCancellation = false
        do {
            try await initializeConnectedIfNeeded()
            guard generation == connectionGeneration, webSocket === task else { throw ClientError.connectionClosed }
        } catch {
            if generation == connectionGeneration {
                let lostGeneration = closeSocket(failing: error)
                await deviceTools?.host.connectionLost(generation: lostGeneration)
            }
            guard isRestarting, !(error is CancellationError), !isRetired else { throw error }
            throw ClientError.gatewayRestarting
        }
        logger.notice("Gateway connected and initialized")
        restartObservedAt = nil
        lastConnectionFailure = nil
        reconnect.connected(at: .now)
        if !livenessSuspended { resumeLivenessChecks() }
        announced = .connected(route.kind)
        hub.emit(.connected(connection: generation, route: route.kind))
    }

    private func handOver(to socket: GatewaySocket, over route: GatewayRoute) async -> Bool {
        logger.notice("Handing the gateway connection over to the \(String(describing: route.kind)) route")
        let lostGeneration = closeSocket(failing: ClientError.connectionClosed)
        let installation = Task(name: "Codex gateway handover") { [self] in try await install(socket, over: route) }
        connectionInFlight = installation
        await endConnection(lostGeneration)
        do {
            try await installation.value
            if connectionInFlight == installation { connectionInFlight = nil }
            return true
        } catch {
            guard connectionInFlight == installation else { return false }
            connectionInFlight = nil
            if !isRetired { await disconnectTransport(reason: error) }
            return false
        }
    }

    private func monitorPongs(socket: URLSessionWebSocketTask, generation: UUID) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled, generation == connectionGeneration, webSocket === socket else { return }
            let now = ContinuousClock.now
            receiveDeadline.recordWake(at: now)
            if receiveDeadline.hasExpired(at: now) {
                logger.notice("Gateway receive progress deadline expired; reconnecting")
                if let stalled = route {
                    await routes?.failed(stalled, error: URLError(.timedOut), startedAt: receiveDeadline.lastReceive)
                }
                guard generation == connectionGeneration, webSocket === socket else { return }
                await disconnect(reason: ClientError.connectionClosed)
                return
            }
            if standby == nil, let stalled = route, receiveDeadline.claimStandby(at: now) {
                standby = Task { [weak self] in await self?.recover(stalled, generation: generation) }
            }
            if pendingPingID == nil {
                sendPing(socket: socket, generation: generation)
            }
        }
    }

    private func recover(_ stalled: GatewayRoute, generation: UUID) async {
        guard await !holdsConnection() else {
            if generation == connectionGeneration { standby = nil }
            return
        }
        logger.notice("Gateway peer silent; racing a standby connection")
        let ordered = await routes?.connectionRoutes() ?? [.configured]
        let started = ContinuousClock.now
        guard let race = try? await race(ordered.filter { $0 != stalled } + ordered.filter { $0 == stalled }) else {
            if generation == connectionGeneration { standby = nil }
            return
        }
        let held = await holdsConnection()
        guard !held, !Task.isCancelled, !livenessSuspended, generation == connectionGeneration,
              connectionInFlight == nil, receiveDeadline.isSuspect(at: .now) else {
            race.socket.task.cancel(with: .goingAway, reason: nil)
            if generation == connectionGeneration { standby = nil }
            return
        }
        standby = nil
        let silentSince = receiveDeadline.lastReceive
        guard await handOver(to: race.socket, over: race.route) else { return }
        if race.route != stalled {
            await routes?.failed(stalled, error: URLError(.timedOut), startedAt: silentSince)
        }
        await routes?.connected(over: race.route, startedAt: started, afterFailing: race.unrecorded)
    }

    private func sendPing(socket: URLSessionWebSocketTask, generation: UUID) {
        guard receiveDeadline.recordPing(at: .now) else { return }
        let id = UUID()
        pendingPingID = id
        socket.sendPing { [weak self] error in
            let receivedAt = ContinuousClock.now
            Task { await self?.receivedPong(id: id, generation: generation, receivedAt: receivedAt, error: error) }
        }
    }

    private func receivedPong(id: UUID, generation: UUID, receivedAt: ContinuousClock.Instant, error: Error?) async {
        guard generation == connectionGeneration, pendingPingID == id else { return }
        pendingPingID = nil
        if let error {
            await disconnect(reason: error)
        } else {
            receiveDeadline.recordPong(at: receivedAt, processedAt: .now)
        }
    }

    func suspendLivenessChecks() {
        livenessSuspended = true
        pingTask?.cancel()
        pingTask = nil
        pendingPingID = nil
        standby?.cancel()
        standby = nil
    }

    func resumeLivenessChecks() {
        guard !isRetired else { return }
        if !livenessSuspended, pingTask != nil {
            if didInitialize, let socket = webSocket {
                sendPing(socket: socket, generation: connectionGeneration)
            }
            return
        }
        livenessSuspended = false
        pingTask?.cancel()
        pingTask = nil
        pendingPingID = nil
        receiveDeadline.resume(at: .now)
        guard didInitialize, let socket = webSocket else {
            expediteReconnect(.foreground)
            return
        }
        let generation = connectionGeneration
        sendPing(socket: socket, generation: generation)
        pingTask = Task { [weak self] in
            await self?.monitorPongs(socket: socket, generation: generation)
        }
    }

    func networkPathChanges() async -> AsyncStream<Void> {
        guard let routes else { return AsyncStream { $0.finish() } }
        return await routes.networkPathChanges()
    }

    func networkPathChanged() {
        guard !isRetired, !livenessSuspended else { return }
        guard didInitialize, let socket = webSocket else {
            expediteReconnect(.networkPath)
            return
        }
        receiveDeadline.allowStandby()
        sendPing(socket: socket, generation: connectionGeneration)
    }

    func takePendingReplayFloor() -> UInt64? {
        hub.takeReplayFloor()
    }

    enum PreferredRouteMove: Sendable {
        case settled
        case deferred
    }

    func moveToPreferredRoute(while allowed: @escaping @Sendable @MainActor () -> Bool) async -> PreferredRouteMove {
        guard let routes, let current = route else { return .settled }
        guard isIdle else { return .deferred }
        let generation = connectionGeneration
        guard await routes.preferredRouteResponds(over: current) else { return .settled }
        guard generation == connectionGeneration, isIdle else { return .deferred }
        let candidates = await routes.preferredRoutes(over: current)
        let started = ContinuousClock.now
        guard !candidates.isEmpty, let race = try? await race(candidates) else { return .settled }
        let stillAllowed = await allowed()
        guard stillAllowed, !Task.isCancelled, generation == connectionGeneration, isIdle else {
            race.socket.task.cancel(with: .goingAway, reason: nil)
            return .settled
        }
        logger.notice("Moving the idle gateway connection to a preferred route")
        guard await handOver(to: race.socket, over: race.route) else { return .settled }
        await routes.moved(to: race.route, startedAt: started, afterFailing: race.unrecorded)
        return .settled
    }

    private var isIdle: Bool {
        isConnected && connectionInFlight == nil && pending.isEmpty
    }

    /// Retirement is terminal: late callbacks cannot reconnect a removed host.
    func retire() async {
        isRetired = true
        wakeReconnectWaiters()
        let connecting = connectionInFlight
        let receiving = receiveTask
        let cleanup = Array(observationCleanupTasks.values)
        await disconnect()
        _ = await connecting?.result
        await receiving?.value
        for task in cleanup { await task.value }
        hub.finishEvents()
    }

    func disconnect(reason: Error? = nil) async {
        connectionInFlight?.cancel()
        connectionInFlight = nil
        await disconnectTransport(reason: reason)
    }

    private func disconnectTransport(reason: Error? = nil) async {
        logger.info(
            "ws disconnect start reason=\(String(describing: reason)) pending=\(self.pending.count) notificationStreams=\(self.hub.streamCount)"
        )
        let lostGeneration = closeSocket(failing: reason ?? ClientError.connectionClosed)
        announceUnavailability()
        disconnections += 1
        await endConnection(lostGeneration)
        logger.info("ws disconnect complete")
    }

    private func endConnection(_ lostGeneration: UUID) async {
        observationCleanupTasks.values.forEach { $0.cancel() }
        observationCleanupTasks.removeAll()
        failedObservationCleanup.removeAll()
        hub.finishAll()
        await deviceTools?.host.connectionLost(generation: lostGeneration)
    }

    private func closeSocket(failing error: Error) -> UUID {
        let wasConnected = isConnected
        if wasConnected { restartObservedAt = nil }
        let error = webSocket.map(observeRestart(closing:)) == true ? ClientError.gatewayRestarting : error
        if wasConnected { reconnect.disconnected(at: .now, restartingSince: restartObservedAt) }
        let lostGeneration = connectionGeneration
        connectionGeneration = UUID()
        receiveDeadline = GatewayReceiveDeadline(now: .now)
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        pendingPingID = nil
        standby?.cancel()
        standby = nil
        didInitialize = false
        supportsRequestCancellation = false
        initializeInFlight = nil
        contentSubscriptionSync?.task.cancel()
        contentSubscriptionSync = nil
        contentSubscriptionState = .unknown
        route = nil
        for request in pending.removeAll() {
            request.timeoutTask.cancel()
            request.fail(error)
        }
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        deviceResultTasks.values.forEach { $0.cancel() }
        deviceResultTasks.removeAll()
        return lostGeneration
    }

    var historyHostID: String { config.url.absoluteString }

    // MARK: - Calls

    func call(method: String, params: JSONValue?, timeout: Duration) async throws -> JSONValue {
        try await connectIfNeeded()
        return try await GatewayRequestRecovery.run(method: method, timeout: timeout) { [self] remaining in
            try await callConnected(method: method, params: params, timeout: remaining)
        }
    }

    private func callConnected(method: String, params: JSONValue?, timeout: Duration) async throws -> JSONValue {
        let id = allocateRequestID()
        let generation = connectionGeneration
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueueRequest(id: id, method: method, params: params, timeout: timeout, completion: .json(continuation))
            }
        } onCancel: { Task { [weak self] in await self?.abandonPending(id: id, generation: generation, error: CancellationError()) } }
    }

    func subscribe(threadID: String) async throws -> (CodexAppServerV2.ThreadSubscribeResponse, GatewayWireReceipt) {
        try await connectIfNeeded()
        for (handle, connection) in failedObservationCleanup {
            try await closeSubscription(handle, connection: connection)
            failedObservationCleanup.removeValue(forKey: handle)
        }
        try await synchronizeContentSubscriptions()
        let id = allocateRequestID()
        let subscribeParams = try encodeToJSONValue(GatewayRequestParams.ThreadReference(threadId: threadID))
        let (data, receipt): (Data, GatewayWireReceipt) = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueueRequest(id: id, method: "thread/subscribe", params: subscribeParams,
                    timeout: timeouts.history, completion: .observed(continuation))
            }
        } onCancel: { /* The owner waits for the handle and closes it even after cancellation. */ }
        do {
            return (try await GatewayFrameDecoder.decodeResult(CodexAppServerV2.ThreadSubscribeResponse.self,
                from: data, dateDecodingStrategy: .deferredToDate), receipt)
        } catch {
            if let handle = await GatewayFrameDecoder.subscriptionHandle(from: data) {
                try await closeSubscription(handle, connection: receipt.connection)
            }
            throw error
        }
    }

    func closeSubscription(_ subscriptionID: String, connection: UUID) async throws {
        guard connection == connectionGeneration, isConnected else { return }
        let id = allocateRequestID()
        // Cleanup owns its bounded RPC even when the selecting task was cancelled.
        let closeParams = try encodeToJSONValue(GatewayRequestParams.Subscription(subscriptionId: subscriptionID))
        let _: JSONValue = try await withCheckedThrowingContinuation { continuation in
            enqueueRequest(id: id, method: "thread/subscription/close",
                params: closeParams, timeout: timeouts.request,
                completion: .json(continuation))
        }
    }

    private func scheduleLateObservationCleanup(handle: String, connection: UUID) {
        guard observationCleanupTasks[handle] == nil else { return }
        observationCleanupTasks[handle] = Task { [weak self] in
            guard let self else { return }
            await self.cleanLateObservation(handle: handle, connection: connection)
        }
    }

    private func cleanLateObservation(handle: String, connection: UUID) async {
        defer { observationCleanupTasks.removeValue(forKey: handle) }
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return }
            do {
                try await closeSubscription(handle, connection: connection)
                return
            } catch {
                logger.error("late observation cleanup failed attempt=\(attempt + 1) error=\(error.localizedDescription)")
                guard attempt < 2 else {
                    if connection == connectionGeneration { failedObservationCleanup[handle] = connection }
                    return
                }
                do { try await Task.sleep(for: .seconds(attempt + 1)) } catch { return }
            }
        }
    }

    func callRaw(method: String, params: JSONValue?, timeout: Duration) async throws -> Data {
        try await connectIfNeeded()
        return try await GatewayRequestRecovery.run(method: method, timeout: timeout) { [self] remaining in
            try await callRawConnected(method: method, params: params, timeout: remaining)
        }
    }

    private func callRawConnected(method: String, params: JSONValue?, timeout: Duration) async throws -> Data {
        let id = allocateRequestID()
        let generation = connectionGeneration
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueueRequest(id: id, method: method, params: params, timeout: timeout, completion: .raw(continuation))
            }
        } onCancel: { Task { [weak self] in await self?.abandonPending(id: id, generation: generation, error: CancellationError()) } }
    }

    private func allocateRequestID() -> Int64 { pending.allocateID() }

    private func enqueueRequest(id: Int64, method: String, params: JSONValue?, timeout: Duration, completion: PendingGatewayRequest.Completion) {
        let request = PendingGatewayRequest(completion: completion, timeoutTask: makeTimeoutTask(id: id, method: method, timeout: timeout, generation: connectionGeneration), method: method, startedAt: .now)
        do {
            guard let webSocket else { throw ClientError.notConnected }
            let message = CodexAppServerV2.JSONRPC.Request(id: .integer(id), method: method, params: params)
            let payload = try JSONEncoder().encode(message)
            guard let string = String(data: payload, encoding: .utf8) else { throw ClientError.invalidMessage }
            logWebSocketFrame(direction: "client->gateway", metadata: "request id=\(id) method=\(method)", payload: string)
            pending.insert(request, id: id)
            let generation = connectionGeneration
            webSocket.send(.string(string)) { [weak self] error in
                if let error { Task { await self?.handleSendFailure(id: id, error: error, generation: generation) } }
            }
        } catch {
            request.timeoutTask.cancel()
            request.fail(error)
        }
    }

    private func sendNotificationConnected(method: String, params: JSONValue?) async throws {
        guard let webSocket else { throw ClientError.notConnected }
        let message = CodexAppServerV2.JSONRPC.Notification(method: method, params: params)
        let payload = try JSONEncoder().encode(message)
        guard let string = String(data: payload, encoding: .utf8) else { throw ClientError.invalidMessage }
        logWebSocketFrame(direction: "client->gateway", metadata: "notification method=\(method)", payload: string)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocket.send(.string(string)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func initializeConnectedIfNeeded() async throws {
        if didInitialize { return }

        if let existing = initializeInFlight {
            try await existing.value
            return
        }

        let task = Task { [self] () async throws -> Void in
            try await self.performInitializeHandshake()
        }
        initializeInFlight = task

        do {
            try await task.value
            initializeInFlight = nil
        } catch {
            initializeInFlight = nil
            throw error
        }
    }

    private func performInitializeHandshake() async throws {
        let generation = connectionGeneration
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let params = try encodeToJSONValue(GatewayRequestParams.Initialize(
            clientInfo: .init(name: "RemoteCoder", title: Self.clientTitle, version: version),
            capabilities: .init(experimentalApi: true)))

        _ = try await callConnected(method: "initialize", params: params, timeout: timeouts.request)
        guard generation == connectionGeneration else { throw ClientError.connectionClosed }
        try await sendNotificationConnected(method: "initialized", params: encodeToJSONValue(GatewayRequestParams.Empty()))
        guard generation == connectionGeneration else { throw ClientError.connectionClosed }
        do {
            _ = try await callConnected(method: "device/tools/declare",
                params: encodeToJSONValue(deviceTools?.host.declarations ?? DeviceToolsDeclare(tools: [])), timeout: timeouts.request)
        } catch {
            logger.notice("Device tools declaration failed; continuing without device tools: \(error.localizedDescription)")
        }
        guard generation == connectionGeneration, webSocket != nil else { throw ClientError.connectionClosed }
        try await synchronizeContentSubscriptions()
        guard generation == connectionGeneration, webSocket != nil else { throw ClientError.connectionClosed }
        didInitialize = true
        logger.notice("Gateway initialized successfully")
    }

    func replaceContentSubscriptions(threadIDs: Set<String>, revision: UInt64) {
        guard !isRetired, revision > contentSubscriptionRevision else { return }
        contentSubscriptionRevision = revision
        let changed = threadIDs != contentSubscriptionThreads || contentSubscriptionFailure != nil
        if threadIDs.count > ConversationContentSubscriptionLimits.maximumThreads {
            contentSubscriptionFailure = .subscriptionCapacity(actual: threadIDs.count,
                limit: ConversationContentSubscriptionLimits.maximumThreads)
        } else if threadIDs.contains(where: {
            !$0.hasPrefix("claude_") || $0 == "claude_" || $0.utf8.count > ConversationContentSubscriptionLimits.maximumThreadIDBytes
        }) {
            contentSubscriptionFailure = .invalidSubscriptionThreadID
        } else {
            contentSubscriptionThreads = threadIDs
            contentSubscriptionFailure = nil
        }
        if let failure = contentSubscriptionFailure {
            if case .unsupported = contentSubscriptionState {} else { contentSubscriptionState = .failed(failure) }
            logger.error("Conversation subscription intent refused: \(failure.localizedDescription)")
            return
        }
        if changed {
            if case .unsupported = contentSubscriptionState {} else { contentSubscriptionState = .unknown }
        }
        if didInitialize, webSocket != nil, contentSubscriptionsNeedSync {
            _ = startContentSubscriptionSync()
        }
    }

    private var contentSubscriptionsNeedSync: Bool {
        guard contentSubscriptionFailure == nil else { return false }
        switch contentSubscriptionState {
        case .unknown: return true
        case .subscribed(let threads): return threads != contentSubscriptionThreads
        case .failed, .unsupported: return false
        }
    }

    private func synchronizeContentSubscriptions() async throws {
        let generation = connectionGeneration
        if let failure = contentSubscriptionFailure {
            if case .unsupported = contentSubscriptionState {} else { contentSubscriptionState = .failed(failure) }
            return
        }
        while contentSubscriptionsNeedSync {
            try await startContentSubscriptionSync().value
            guard generation == connectionGeneration, webSocket != nil else { throw ClientError.connectionClosed }
            try Task.checkCancellation()
        }
    }

    private func startContentSubscriptionSync() -> Task<Void, Error> {
        if let existing = contentSubscriptionSync { return existing.task }
        let id = UUID()
        let generation = connectionGeneration
        let task = Task { [self] in
            defer { if contentSubscriptionSync?.id == id { contentSubscriptionSync = nil } }
            while contentSubscriptionsNeedSync {
                guard generation == connectionGeneration, webSocket != nil else { throw ClientError.connectionClosed }
                try Task.checkCancellation()
                let threads = contentSubscriptionThreads
                let revision = contentSubscriptionRevision
                do {
                    _ = try await callConnected(method: "conversation/subscriptions/set",
                        params: .object(["threadIds": .array(threads.sorted().map(JSONValue.string))]), timeout: timeouts.request)
                    guard generation == connectionGeneration else { throw ClientError.connectionClosed }
                    if contentSubscriptionFailure == nil, threads == contentSubscriptionThreads {
                        contentSubscriptionState = .subscribed(threads)
                    }
                } catch {
                    guard generation == connectionGeneration, webSocket != nil else { throw ClientError.connectionClosed }
                    try Task.checkCancellation()
                    let failure: ClientError
                    if let rpc = error as? GatewayRPCFailure {
                        failure = .serverError(message: rpc.message, code: rpc.code)
                    } else if let client = error as? ClientError {
                        switch client {
                        case .serverError, .requestTimedOut: failure = client
                        default: throw error
                        }
                    } else {
                        throw error
                    }
                    if case .serverError(_, let code) = failure, let code, code == -32600 || code == -32601 {
                        contentSubscriptionState = .unsupported(code: code)
                        logger.notice("Conversation subscriptions unsupported; history and legacy content remain available")
                    } else {
                        if contentSubscriptionFailure == nil, threads == contentSubscriptionThreads {
                            contentSubscriptionState = .failed(failure)
                        }
                        logger.error("Conversation subscription revision=\(revision) failed; history and replay remain available: \(failure.localizedDescription)")
                    }
                }
            }
        }
        contentSubscriptionSync = (id, task)
        return task
    }

    private static var clientTitle: String {
        #if os(macOS)
        "RemoteCoder macOS"
        #else
        "RemoteCoder iOS"
        #endif
    }

    @discardableResult
    private func abandonPending(id: Int64, generation: UUID, error: Error) -> Bool {
        guard generation == connectionGeneration, let request = pending.remove(id: id) else { return false }
        request.timeoutTask.cancel()
        request.fail(error)
        guard supportsRequestCancellation, let webSocket else { return true }
        struct Cancellation: Encodable {
            let jsonrpc = "2.0"
            let method = "$/cancelRequest"
            let params: Params
            struct Params: Encodable { let id: Int64 }
        }
        do {
            let payload = try JSONEncoder().encode(Cancellation(params: .init(id: id)))
            webSocket.send(.string(String(decoding: payload, as: UTF8.self))) { [logger] error in
                if let error { logger.notice("Request cancellation delivery failed: \(error.localizedDescription)") }
            }
        } catch {
            logger.error("Request cancellation encoding failed: \(error.localizedDescription)")
        }
        return true
    }

    @discardableResult
    private func failPending(id: Int64, error: Error) -> Bool {
        guard let request = pending.remove(id: id) else { return false }
        request.timeoutTask.cancel()
        request.fail(error)
        return true
    }

    private func handleSendFailure(id: Int64, error: Error, generation: UUID) async {
        _ = failPending(id: id, error: error)
        guard generation == connectionGeneration, didInitialize else { return }
        await disconnect(reason: error)
    }

    private func makeTimeoutTask(id: Int64, method: String, timeout: Duration, generation: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let didFail = await self.abandonPending(
                id: id, generation: generation,
                error: ClientError.requestTimedOut(method: method)
            )
            if didFail {
                self.logger.info("request timeout isolated to id=\(id) method=\(method)")
            }
        }
    }

    private func receiveLoop(socket webSocket: URLSessionWebSocketTask, generation: UUID,
                             first: URLSessionWebSocketTask.Message) async {
        var first = Optional(first)
        while !Task.isCancelled {
            guard generation == connectionGeneration, self.webSocket === webSocket else { return }
            do {
                let message: URLSessionWebSocketTask.Message
                if let early = first.take() {
                    message = early
                } else {
                    receiveDeadline.listen(at: .now)
                    message = try await webSocket.receive()
                }
                guard generation == connectionGeneration, self.webSocket === webSocket else { return }
                receiveDeadline.recordReceive(at: .now)
                let data: Data
                let rawString: String
                switch message {
                case .data(let d):
                    data = d
                    rawString = String(data: d, encoding: .utf8) ?? "<non-utf8 data frame bytes=\(d.count)>"
                case .string(let s):
                    guard let d = s.data(using: .utf8) else { throw ClientError.invalidMessage }
                    data = d
                    rawString = s
                @unknown default:
                    throw ClientError.invalidMessage
                }

                let frame: GatewayFrameDecoder.Frame
                let rawIDs = pending.rawResponseIDs
                do {
                    if !rawIDs.isEmpty {
                        frame = try await GatewayFrameDecoder.decode(data, rawResponseIDs: rawIDs)
                    } else {
                        frame = try GatewayFrameDecoder.decodeSynchronously(data, rawResponseIDs: [])
                    }
                } catch let failure as GatewayFrameDecoder.Failure {
                    let opcode = if case .string = message { 1 } else { 2 }
                    logger.error("Gateway frame decode failed opcode=\(opcode) bytes=\(data.count) decode=\(failure.decodePath.rawValue) kind=\(failure.kind) path=\(failure.path) prefix=\(failure.prefix)")
                    throw ClientError.invalidResponse
                }
                guard generation == connectionGeneration, self.webSocket === webSocket else { return }
                wireSequence += 1
                let receipt = GatewayWireReceipt(connection: connectionGeneration, sequence: wireSequence)
                switch frame {
                case .largeFrame(let bytes):
                    receiveDeadline.announceLargeFrame(bytes: bytes, at: .now)
                    continue
                case .rawResponse(let id, let raw):
                    if let request = pending.remove(id: id) {
                        request.timeoutTask.cancel()
                        logger.notice("rpc method=\(request.method) bytes=\(raw.count) elapsed=\(String(describing: request.startedAt.duration(to: .now))) outcome=success")
                        request.succeed(raw: raw, receipt: receipt)
                    } else if let handle = await GatewayFrameDecoder.subscriptionHandle(from: raw) {
                        scheduleLateObservationCleanup(handle: handle, connection: receipt.connection)
                    }
                    continue
                case .response(let response):
                    logWebSocketFrame(
                        direction: "gateway->client",
                        metadata: "response id=\(response.id.logDescription)",
                        payload: rawString
                    )
                    if case .integer(let id) = response.id {
                        if let request = pending.remove(id: id) {
                            request.timeoutTask.cancel()
                            // .debug: per-frame stream-path noise; the gateway
                            // journal records every rpc response durably.
                            debugLogger.debug("ws response matched id=\(id, privacy: .public) pendingRemaining=\(self.pending.count, privacy: .public)")
                            let elapsed = request.startedAt.duration(to: .now)
                            logger.notice("rpc method=\(request.method) bytes=\(data.count) elapsed=\(String(describing: elapsed)) outcome=success")
                            request.succeed(response.result, raw: data, receipt: receipt)
                        } else {
                            logger.notice("ws response arrived after request completion id=\(id)")
                            if let fields = response.result.objectValue, fields["status"]?.stringValue == "subscribed",
                               let handle = fields["subscriptionId"]?.stringValue {
                                scheduleLateObservationCleanup(handle: handle, connection: receipt.connection)
                            }
                        }
                    }
                case .error(let response):
                    logWebSocketFrame(
                        direction: "gateway->client",
                        metadata: "error id=\(response.id.logDescription) code=\(response.error.code)",
                        payload: rawString
                    )
                    if case .integer(let id) = response.id {
                        if let request = pending.remove(id: id) {
                            request.timeoutTask.cancel()
                            logger.error(
                                "ws error matched id=\(id) code=\(response.error.code) message=\(response.error.message)"
                            )
                            let code = Int(response.error.code)
                            if let failure = GatewayRPCFailure(code: code, message: response.error.message, data: response.error.data) {
                                request.fail(failure)
                            } else {
                                request.fail(ClientError.serverError(message: response.error.message, code: Int(response.error.code)))
                            }
                        } else if response.error.data?.objectValue?["kind"]?.stringValue != "requestCancelled" {
                            logger.notice("ws error arrived after request completion id=\(id)")
                        }
                    }
                case .notification(let notification, let server, let sequence):
                    if case .daemonReady(let ready) = server { supportsRequestCancellation = ready.cancelRequest }
                    PerfBuild.recordFrame(rawString)
                    logWebSocketFrame(
                        direction: "gateway->client",
                        metadata: "notification method=\(notification.method)",
                        payload: rawString
                    )
                    if case .transportError(let error) = server, error.kind == "messageTooLarge" {
                        await disconnect(reason: ClientError.historyCapacity(
                            actualBytes: error.actualBytes ?? 0,
                            limitBytes: error.limitBytes ?? GatewayTransportLimits.maximumMessageSizeBytes))
                        return
                    }
                    if await routeDeviceToolNotification(method: notification.method, params: notification.params,
                                                         generation: generation) { continue }
                    handleNotification(CodexGatewayNotification(
                        method: notification.method, params: notification.params, server: server,
                        sequence: sequence, receipt: receipt))
                case .request(let request):
                    logWebSocketFrame(
                        direction: "gateway->client",
                        metadata: "request id=\(request.id.logDescription) method=\(request.method)",
                        payload: rawString
                    )
                    await handleRequest(request)
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == connectionGeneration, self.webSocket === webSocket else { return }
                let ns = error as NSError
                if webSocket.closeCode.rawValue == Self.restartingCloseCode {
                    logger.notice("Gateway closed the connection for a planned restart")
                } else if ns.domain == NSPOSIXErrorDomain, ns.code == 40 {
                    logger.error(
                        "Gateway receive loop failed (message too long; max=\(self.webSocket?.maximumMessageSize ?? -1)): \(String(describing: error))"
                    )
                } else {
                    logger.error("Gateway receive loop failed: \(String(describing: error))")
                }
                if didInitialize {
                    await disconnect(reason: error)
                } else {
                    let lostGeneration = closeSocket(failing: error)
                    await deviceTools?.host.connectionLost(generation: lostGeneration)
                }
                return
            }
        }
    }

    private func routeDeviceToolNotification(method: String, params: JSONValue?, generation: UUID) async -> Bool {
        guard method == "device/tool/invoke" || method == "device/tool/cancel" else { return false }
        guard let deviceTools else {
            logger.error("Received device tool notification without registered tools")
            return true
        }
        do {
            guard let params else { throw ClientError.invalidMessage }
            let data = try JSONEncoder().encode(params)
            if method == "device/tool/cancel" {
                let cancel = try JSONDecoder().decode(DeviceToolCancel.self, from: data)
                await deviceTools.host.cancel(cancel, generation: generation)
            } else {
                let invoke = try JSONDecoder().decode(DeviceToolInvoke.self, from: data)
                let context = DeviceToolContext(host: deviceTools.uploadHost, uploader: deviceTools.uploader,
                                               deadlineUnixMs: invoke.deadlineUnixMs)
                let refusal = await deviceTools.host.invoke(invoke, generation: generation, context: context) { [weak self] result in
                    await self?.scheduleDeviceToolResult(result, generation: generation)
                }
                if let refusal { scheduleDeviceToolResult(refusal, generation: generation) }
            }
        } catch {
            logger.error("Invalid device tool notification method=\(method): \(error.localizedDescription)")
        }
        return true
    }

    private func scheduleDeviceToolResult(_ result: DeviceToolResult, generation: UUID) {
        guard generation == connectionGeneration, webSocket != nil else { return }
        guard deviceResultTasks.count < 8 else {
            logger.error("Device tool result delivery capacity exceeded")
            return
        }
        let id = UUID()
        deviceResultTasks[id] = Task { [weak self] in
            await self?.sendDeviceToolResult(result, generation: generation)
            await self?.removeDeviceResultTask(id)
        }
    }

    private func removeDeviceResultTask(_ id: UUID) {
        deviceResultTasks.removeValue(forKey: id)
    }

    private func sendDeviceToolResult(_ result: DeviceToolResult, generation: UUID) async {
        guard generation == connectionGeneration, webSocket != nil else { return }
        do {
            let data = try await callRawConnected(method: "device/tool/result", params: encodeToJSONValue(result), timeout: timeouts.request)
            let receipt = try await GatewayFrameDecoder.decodeResult(DeviceToolResultReceipt.self,
                from: data, dateDecodingStrategy: .deferredToDate)
            if !receipt.accepted { logger.notice("Gateway declined a late or unknown device tool result") }
        } catch is CancellationError {
            return
        } catch {
            guard generation == connectionGeneration else { return }
            logger.error("Device tool result delivery failed: \(error.localizedDescription)")
        }
    }

    private func handleNotification(_ note: CodexGatewayNotification) {
        let method = note.method
        // .debug: fires per notification; the gateway journal holds every
        // notify frame with its payload.
        debugLogger.debug(
            "notification fanout method=\(method, privacy: .public) globalStreams=\(self.hub.streamCount)"
        )
        if hub.publish(note) {
            logger.notice("notification buffer dropped an event; history reconciliation required")
        }
    }

    #if RC_PERF_HARNESS
    /// Perf harness replay: the same decode and fan-out a received text frame takes.
    func perfInjectNotificationFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? GatewayFrameDecoder.decodeSynchronously(data, rawResponseIDs: []),
              case .notification(let notification, let server, let sequence) = frame else { return }
        wireSequence += 1
        let receipt = GatewayWireReceipt(connection: connectionGeneration, sequence: wireSequence)
        logWebSocketFrame(direction: "gateway->client", metadata: "notification method=\(notification.method)", payload: text)
        handleNotification(CodexGatewayNotification(method: notification.method, params: notification.params, server: server,
                                                    sequence: sequence, receipt: receipt))
    }
    #endif

    private func removeNotificationContinuation(id: UUID) {
        hub.remove(id: id)
    }

    private func removeEventSubscriber(id: UUID) {
        hub.removeEventSubscriber(id: id)
    }

    private func handleRequest(_ request: CodexAppServerV2.JSONRPC.Request) async {
        guard request.method != "account/chatgptAuthTokens/refresh" else { return }

        // Surface the incoming request as a notification for UI visibility, but also
        // respond immediately so Codex doesn't stall waiting for a reply.
        handleNotification(CodexGatewayNotification(method: request.method, params: request.params,
            server: ServerNotification.decode(method: request.method, params: request.params),
            receipt: GatewayWireReceipt(connection: connectionGeneration, sequence: wireSequence)))

        guard let webSocket else { return }

        let responseMessage: CodexAppServerV2.JSONRPC.Message
        if let reply = DispatchPolicy.declineReplies[request.method] {
            responseMessage = .response(CodexAppServerV2.JSONRPC.Response(id: request.id, result: reply))
        } else {
            responseMessage = .error(
                CodexAppServerV2.JSONRPC.ErrorResponse(
                    error: CodexAppServerV2.JSONRPC.ErrorObject(
                        code: -32601,
                        data: nil,
                        message: "RemoteCoder does not support client-side requests (\(request.method))."
                    ),
                    id: request.id
                )
            )
        }

        do {
            let data = try JSONEncoder().encode(responseMessage)
            guard let string = String(data: data, encoding: .utf8) else { return }
            logWebSocketFrame(
                direction: "client->gateway",
                metadata: "response to request id=\(request.id.logDescription) method=\(request.method)",
                payload: string
            )
            webSocket.send(.string(string)) { [logger] error in
                if let error {
                    logger.error("Failed to send request response: \(String(describing: error))")
                }
            }
        } catch {
            logger.error("Failed to encode request response: \(String(describing: error))")
        }
    }

    func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func callDecodable<T: Decodable & Sendable>(
        method: String,
        params: JSONValue?,
        timeout: Duration
    ) async throws -> T {
        let data = try await callRaw(method: method, params: params, timeout: timeout)
        return try await GatewayFrameDecoder.decodeResult(T.self, from: data, dateDecodingStrategy: .deferredToDate)
    }

    private func logWebSocketFrame(direction: String, metadata: String, payload: String) {
        // Deliberately .debug, which on iOS is memory-only and never reaches the host log
        // copy: this fires on every frame in both directions, and the gateway journal already
        // records each one server-side with its full payload.
        debugLogger.debug(
            "ws frame \(direction, privacy: .public) \(metadata, privacy: .public) bytes=\(payload.utf8.count)"
        )
    }
}

private extension CodexAppServerV2.JSONRPC.RequestId {
    var logDescription: String {
        switch self {
        case .integer(let value):
            return "\(value)"
        case .string(let value):
            return value
        }
    }
}

nonisolated struct GatewayReceiveDeadline {
    private static let probeInterval = Duration.seconds(2)
    private static let maximumGrace = Duration.seconds(15)
    private static let shortestSuspicion = Duration.seconds(2)
    private static let longestSuspicion = Duration.seconds(4)

    private struct Ping {
        let sentAt: ContinuousClock.Instant
        var samplesRoundTrip = true
        var standbyClaimed = false
    }

    private(set) var lastReceive: ContinuousClock.Instant
    private var listeningSince: ContinuousClock.Instant?
    private var previousWake: ContinuousClock.Instant
    private var nextPingAt: ContinuousClock.Instant
    private var pendingPing: Ping?
    private var smoothedRoundTrip: Duration?
    private var announcedFrameDeadline: ContinuousClock.Instant?

    init(now: ContinuousClock.Instant) {
        lastReceive = now
        listeningSince = now
        previousWake = now
        nextPingAt = now
    }

    mutating func recordReceive(at now: ContinuousClock.Instant) {
        lastReceive = max(lastReceive, now)
        listeningSince = nil
        announcedFrameDeadline = nil
    }

    mutating func listen(at now: ContinuousClock.Instant) {
        listeningSince = now
    }

    mutating func announceLargeFrame(bytes: Int, at now: ContinuousClock.Instant) {
        let grace = Duration.seconds(Double(bytes) / Double(GatewayTransportLimits.largeFramePayloadBytesPerSecond) + 4)
        announcedFrameDeadline = now.advanced(by: grace)
        lastReceive = max(lastReceive, now)
    }

    @discardableResult
    mutating func recordPing(at now: ContinuousClock.Instant) -> Bool {
        guard pendingPing == nil, now >= nextPingAt else { return false }
        pendingPing = Ping(sentAt: now)
        nextPingAt = now.advanced(by: Self.probeInterval)
        return true
    }

    mutating func recordPong(at receivedAt: ContinuousClock.Instant, processedAt: ContinuousClock.Instant) {
        recordWake(at: processedAt)
        if let ping = pendingPing, ping.samplesRoundTrip {
            let sample = ping.sentAt.duration(to: receivedAt)
            if let smoothed = smoothedRoundTrip {
                smoothedRoundTrip = smoothed + (sample - smoothed) / 8
            } else {
                smoothedRoundTrip = sample
            }
        }
        pendingPing = nil
        if announcedFrameDeadline == nil { lastReceive = max(lastReceive, receivedAt) }
    }

    mutating func resume(at now: ContinuousClock.Instant) {
        if announcedFrameDeadline == nil { lastReceive = now }
        previousWake = now
        pendingPing = nil
        nextPingAt = now
        smoothedRoundTrip = nil
    }

    mutating func recordWake(at now: ContinuousClock.Instant) {
        if previousWake.duration(to: now) > .seconds(3) {
            if announcedFrameDeadline == nil { lastReceive = now }
            pendingPing?.samplesRoundTrip = false
        }
        previousWake = now
    }

    func isSuspect(at now: ContinuousClock.Instant) -> Bool {
        guard announcedFrameDeadline == nil, let listeningSince, let pendingPing else { return false }
        let patience = smoothedRoundTrip.map { max($0 * 3 / 2, min(Self.longestSuspicion, max(Self.shortestSuspicion, $0 * 3))) }
            ?? Self.longestSuspicion
        return max(lastReceive, listeningSince, pendingPing.sentAt).duration(to: now) >= patience
    }

    mutating func claimStandby(at now: ContinuousClock.Instant) -> Bool {
        guard pendingPing?.standbyClaimed == false, isSuspect(at: now) else { return false }
        pendingPing?.standbyClaimed = true
        return true
    }

    mutating func allowStandby() {
        pendingPing?.standbyClaimed = false
    }

    func hasExpired(at now: ContinuousClock.Instant) -> Bool {
        if let announcedFrameDeadline { return now >= announcedFrameDeadline }
        let grace = min(Self.maximumGrace, max(.seconds(8), (smoothedRoundTrip ?? .zero) * 4))
        let anchor = max(lastReceive, pendingPing?.sentAt ?? lastReceive)
        let expiresAt = min(anchor.advanced(by: grace), lastReceive.advanced(by: Self.maximumGrace + Self.probeInterval))
        return now >= expiresAt
    }
}
