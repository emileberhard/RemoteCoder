import Foundation
import OSLog

@MainActor
protocol GatewayEventSink: AnyObject {
    var isRetired: Bool { get }
    var acceptsGatewayEvents: Bool { get }
    var acceptsConnectionReports: Bool { get }
    func gatewayConnectionChanged(_ link: GatewayEventPump.Link, connection: UUID?) async
    func gatewayConnectivityChanged(_ connectivity: GatewayConnectivity) async
    func gatewayNetworkPathChanged()
    func gatewayActivityRefreshRequested()
    func apply(gatewayEvent event: RoutedGatewayEvent, replay: Bool) async
    func gatewayThreadClosed(_ threadID: String, receipt: GatewayWireReceipt?)
    func gatewayQuestionsChanged(_ change: ServerNotification.QuestionsChanged)
    func defersReplay(_ event: RoutedGatewayEvent) -> Bool
    func reconcile(gap: ReplayProgress.Gap) async
}

extension GatewayEventSink {
    var acceptsGatewayEvents: Bool { !isRetired }
}

@MainActor
final class GatewayEventPump {
    enum Link: String, Sendable { case connecting, connected, reconnecting, disconnected }

    @TaskLocal static var delivery: Delivery?

    struct Delivery: Sendable {
        private let pump: WeakPump
        private let generation: UUID

        fileprivate init(pump: GatewayEventPump, generation: UUID) {
            self.pump = WeakPump(value: pump)
            self.generation = generation
        }

        @MainActor var isCurrent: Bool {
            guard let pump = pump.value else { return false }
            return !Task.isCancelled && generation == pump.generation && pump.isLive
        }
    }

    private struct WeakPump: Sendable {
        weak var value: GatewayEventPump?
    }

    private struct ReplayCoverage: Sendable {
        let through: UInt64
        let deferred: Set<UInt64>

        func applied(_ sequence: UInt64) -> Bool { sequence <= through && !deferred.contains(sequence) }
    }

    private let gateway: GatewayClient
    private let conversations: ConversationSessions
    private weak var sink: (any GatewayEventSink)?
    private let logger = AppLogger(category: "GatewayNotificationPump")
    private var task: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var generation = UUID()
    private var cursor = NotificationCursor()
    private var pendingGap: ReplayProgress.Gap?
    private var gapRecoveryTask: Task<Void, Never>?

    init(gateway: GatewayClient, conversations: ConversationSessions, sink: any GatewayEventSink) {
        self.gateway = gateway
        self.conversations = conversations
        self.sink = sink
    }

    private var isLive: Bool { sink.map { $0.acceptsGatewayEvents } ?? false }

    func startIfNeeded() {
        guard task == nil, isLive else { return }
        let gateway = self.gateway
        let conversations = self.conversations
        let target = WeakPump(value: self)
        generation = UUID()
        let generation = generation
        task = Task {
            await Self.run(gateway: gateway, conversations: conversations, target: target, generation: generation)
        }
        connectionTask = Task { [weak self] in
            let events = await gateway.connectionEvents()
            let connectivity = await gateway.connectivity
            if let self, self.isLive, !Task.isCancelled {
                await self.sink?.gatewayConnectivityChanged(connectivity)
            }
            for await event in events {
                guard let self, self.isLive, !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
        networkTask = Task { [weak self] in
            for await _ in await gateway.networkPathChanges() {
                guard !Task.isCancelled, self?.isLive == true else { return }
                await gateway.networkPathChanged()
                guard !Task.isCancelled, self?.isLive == true else { return }
                self?.sink?.gatewayNetworkPathChanged()
            }
        }
        resumeGapRecovery()
    }

    @discardableResult
    func stop() -> [Task<Void, Never>] {
        generation = UUID()
        let running = [task, connectionTask, networkTask, gapRecoveryTask].compactMap { $0 }
        task?.cancel()
        task = nil
        connectionTask?.cancel()
        connectionTask = nil
        networkTask?.cancel()
        networkTask = nil
        gapRecoveryTask?.cancel()
        gapRecoveryTask = nil
        return running
    }

    func enqueueGap(_ gap: ReplayProgress.Gap) {
        guard isLive else { return }
        pendingGap = Self.combinedGap(pendingGap, gap)
        resumeGapRecovery()
    }

    func replayThread(afterSequence: UInt64, epoch: String, threadID: String, limit: Int?) async throws {
        let generation = self.generation
        var cursor = NotificationCursor()
        cursor.adopt(epoch: epoch)
        var progress = ReplayProgress(cursor: cursor, afterSequence: afterSequence)
        var missedEvents = false
        defer { if missedEvents { enqueueGap(.threads([threadID])) } }
        do {
            while true {
                try Task.checkCancellation()
                guard generation == self.generation, isLive else { throw CancellationError() }
                let response = try await gateway.replayThreadNotifications(
                    afterSequence: progress.nextAfterSequence,
                    epoch: progress.cursor.epoch,
                    threadID: threadID,
                    limit: limit
                )
                try Task.checkCancellation()
                guard generation == self.generation, isLive else { throw CancellationError() }
                await conversations.adoptNotificationEpoch(response.epoch)
                logger.notice(
                    "replaying \(response.notifications.count) missed notifications after \(afterSequence) thread=\(threadID) throughSequence=\(response.throughSequence)"
                )
                let events = await Self.routeReplayedNotifications(response.notifications)
                for event in events { await apply(event, replay: true, generation: generation) }
                try Task.checkCancellation()
                guard generation == self.generation, isLive else { throw CancellationError() }
                let step = progress.complete(response.page)
                if step.gap != nil { missedEvents = true }
                if !step.hasMore { break }
            }
        } catch {
            if !(error is CancellationError), !Task.isCancelled { missedEvents = true }
            throw error
        }
    }

    private static func combinedGap(_ previous: ReplayProgress.Gap?, _ next: ReplayProgress.Gap?) -> ReplayProgress.Gap? {
        switch (previous, next) {
        case (.some(.allThreads), _), (_, .some(.allThreads)): return .allThreads
        case let (.some(.threads(left)), .some(.threads(right))):
            let combined = left.union(right)
            return combined.count > 256 ? .allThreads : .threads(combined)
        case (nil, let gap?), (let gap?, nil): return gap
        case (nil, nil): return nil
        }
    }

    private func resumeGapRecovery() {
        guard gapRecoveryTask == nil, pendingGap != nil, task != nil, isLive else { return }
        gapRecoveryTask = Task { [weak self] in
            while let gap = self?.takePendingGap() {
                await self?.sink?.reconcile(gap: gap)
                if Task.isCancelled { self?.restorePendingGap(gap); return }
            }
            if !Task.isCancelled { self?.gapRecoveryTask = nil }
        }
    }

    private func restorePendingGap(_ gap: ReplayProgress.Gap) {
        pendingGap = Self.combinedGap(gap, pendingGap)
    }

    private func takePendingGap() -> ReplayProgress.Gap? {
        guard !Task.isCancelled, isLive else { return nil }
        defer { pendingGap = nil }
        return pendingGap
    }

    private func handle(_ event: GatewayConnectionEvent) async {
        switch event {
        case .connected(_, let route):
            await sink?.gatewayConnectivityChanged(.connected(route))
        case .restarting:
            await sink?.gatewayConnectivityChanged(.restarting)
        case .disconnected:
            await sink?.gatewayConnectivityChanged(.disconnected)
        case .historyGap(let threads, let allThreads):
            enqueueGap(allThreads ? .allThreads : .threads(threads))
        }
    }

    private func report(_ link: Link, generation: UUID) async {
        guard generation == self.generation, let sink, !sink.isRetired, sink.acceptsConnectionReports else { return }
        let connection = link == .connected ? await gateway.connectionIdentity : nil
        if connection != nil {
            guard generation == self.generation, !sink.isRetired else { return }
        }
        await sink.gatewayConnectionChanged(link, connection: connection)
    }

    private func requestActivityRefresh() {
        sink?.gatewayActivityRefreshRequested()
    }

    private func cursorSnapshot() -> NotificationCursor {
        cursor
    }

    private func storeCursor(_ stored: NotificationCursor, generation: UUID) {
        guard generation == self.generation, !Task.isCancelled else { return }
        if stored.epoch == cursor.epoch, let sequence = stored.sequence {
            cursor.advance(to: sequence)
        } else if generation == self.generation {
            cursor = stored
        }
    }

    private func takeReplayAfter() async -> UInt64? {
        let floor = await gateway.takePendingReplayFloor()
        return cursor.replayAfter(pendingReplayFloor: floor)
    }

    private func threadClosed(_ threadID: String, receipt: GatewayWireReceipt?) {
        sink?.gatewayThreadClosed(threadID, receipt: receipt)
    }

    private func questionsChanged(_ change: ServerNotification.QuestionsChanged, generation: UUID) {
        guard generation == self.generation else { return }
        sink?.gatewayQuestionsChanged(change)
    }

    private func apply(_ event: RoutedGatewayEvent, replay: Bool, generation: UUID) async {
        guard generation == self.generation, isLive, !Task.isCancelled else { return }
        await Self.$delivery.withValue(Delivery(pump: self, generation: generation)) {
            await sink?.apply(gatewayEvent: event, replay: replay)
        }
    }

    private func replayMissed(afterSequence: UInt64, generation: UUID) async -> ReplayCoverage? {
        var progress = ReplayProgress(cursor: cursor, afterSequence: afterSequence)
        var replayed: ReplayCoverage?
        var deferred = Set<UInt64>()
        var gap: ReplayProgress.Gap?
        defer { if let gap { enqueueGap(gap) } }
        do {
            while generation == self.generation, isLive, !Task.isCancelled {
                let response = try await gateway.replayNotifications(
                    afterSequence: progress.nextAfterSequence, epoch: progress.cursor.epoch)
                guard generation == self.generation, isLive else { break }
                await conversations.adoptNotificationEpoch(response.epoch)
                let events = await Self.routeReplayedNotifications(response.notifications)
                for event in events {
                    if sink?.defersReplay(event) == true, let sequence = event.sequence { deferred.insert(sequence) }
                    await apply(event, replay: true, generation: generation)
                }
                guard generation == self.generation, isLive else { break }
                let step = progress.complete(response.page)
                cursor = progress.cursor
                replayed = ReplayCoverage(through: response.throughSequence, deferred: deferred)
                gap = Self.combinedGap(gap, step.gap)
                logger.notice("replayed page count=\(response.notifications.count) throughSequence=\(response.throughSequence) hasMore=\(response.hasMore)")
                if !step.hasMore { break }
            }
        } catch {
            if !(error is CancellationError), !Task.isCancelled {
                logger.notice("Notification replay failed; reconciling every open conversation: \(String(describing: error))")
                gap = .allThreads
            }
        }
        return replayed
    }

    @concurrent
    private nonisolated static func routeReplayedNotifications(
        _ entries: [CodexGatewayDaemon.ReplayedNotification]
    ) async -> [RoutedGatewayEvent] {
        entries.compactMap { GatewayNotificationRouting.route(replayed: $0) }
    }

    /// Consumes the gateway broadcast off the main actor: routing filters
    /// uninteresting methods and decodes typed payloads there, turn events go
    /// straight to their conversation session, and only lifecycle and
    /// non-turn events hop to the main actor.
    @concurrent
    private nonisolated static func run(
        gateway: GatewayClient,
        conversations: ConversationSessions,
        target: WeakPump,
        generation: UUID
    ) async {
        let logger = AppLogger(category: "GatewayNotificationPump")
        var keptConnection = false
        while Task.isCancelled == false {
            await conversations.revokeStreamingPrefixes()
            let disconnections = await gateway.disconnections
            let stream = await gateway.notifications()
            var replayed: ReplayCoverage?
            do {
                // Subscribe before connecting/replaying so incoming frames are not lost.
                let afterSequence = await target.value?.takeReplayAfter()
                if !keptConnection {
                    await target.value?.report(afterSequence == nil ? .connecting : .reconnecting, generation: generation)
                }
                keptConnection = false
                try await gateway.connectWhenPermitted()
                await target.value?.report(.connected, generation: generation)

                // Replay notifications missed since the last delivered gateway sequence.
                guard let pump = target.value else { return }
                if let afterSequence {
                    replayed = await pump.replayMissed(afterSequence: afterSequence, generation: generation)
                }
                if !Task.isCancelled { await target.value?.requestActivityRefresh() }
            } catch {
                await target.value?.report(.disconnected, generation: generation)
                logger.notice("Gateway connect failed for notification listener: \(String(describing: error))")
                if Task.isCancelled { return }
                if case GatewayClient.ClientError.retired = error { return }
                continue
            }

            var cursor = await target.value?.cursorSnapshot() ?? NotificationCursor()
            for await note in stream {
                if Task.isCancelled { break }
                if case .daemonReady(let ready) = note.server {
                    await conversations.adoptNotificationEpoch(ready.epoch)
                    cursor.adoptConnection(epoch: ready.epoch, deliveredThrough: ready.sequence)
                    await target.value?.apply(.providerHealth(ready.providerHealth), replay: false, generation: generation)
                    continue
                }
                let isControl = switch note.server {
                case .threadClosed, .questionsChanged, .providerHealthChanged: true
                default: false
                }
                if let replayed, let sequence = note.sequence, replayed.applied(sequence), !isControl { continue }
                switch note.server {
                case .threadClosed(let threadID):
                    await target.value?.threadClosed(threadID, receipt: note.receipt)
                case .questionsChanged(let change):
                    await target.value?.questionsChanged(change, generation: generation)
                default:
                    break
                }
                guard let pump = target.value else { return }
                switch GatewayNotificationRouting.route(note) {
                case .turnEvent(let turnEvent):
                    guard !Task.isCancelled else { break }
                    if turnEvent.isLifecycle {
                        await pump.apply(.turnEvent(turnEvent), replay: false, generation: generation)
                    } else {
                        await conversations.ingest(turnEvent, replay: false)
                    }
                case .some(let event):
                    await pump.apply(event, replay: false, generation: generation)
                case nil:
                    break
                }
                if Task.isCancelled { break }
                if let sequence = note.sequence {
                    cursor.advance(to: sequence)
                }
            }

            await target.value?.storeCursor(cursor, generation: generation)
            if Task.isCancelled { return }
            keptConnection = await gateway.disconnections == disconnections
            if keptConnection { continue }
            await target.value?.report(.disconnected, generation: generation)
        }
    }
}
