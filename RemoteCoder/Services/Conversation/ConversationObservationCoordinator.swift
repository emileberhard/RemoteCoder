import Foundation
import Observation

@Observable @MainActor
final class ConversationObservationCoordinator {
    enum State: Equatable {
        case detached, attaching, catchingUp, live, storedOnly, failed(String)
    }

    private final class Subscription {
        let threadID: String
        var session: ConversationSession?
        var generation = UUID()
        var pendingClosure: GatewayWireReceipt?
        var task: Task<Void, Never>?
        var handle: (id: String, connection: UUID, sequence: UInt64, capture: UUID, session: ConversationSession)?

        init(threadID: String) { self.threadID = threadID }
    }

    private var states: [String: State] = [:]
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private var isQuiescing = false
    @ObservationIgnored private let gateway: GatewayClient
    @ObservationIgnored private let history: GatewayHistoryService
    @ObservationIgnored private let capacity: Int
    @ObservationIgnored private var subscriptions: [String: Subscription] = [:]
    @ObservationIgnored private var connectionID: UUID?

    init(gateway: GatewayClient, history: GatewayHistoryService, capacity: Int) {
        self.gateway = gateway
        self.history = history
        self.capacity = capacity
    }

    func state(of threadID: String?) -> State {
        threadID.flatMap { states[$0] } ?? .detached
    }

    func observe(_ desired: [String: ConversationSession]) {
        guard !isRetired, !isQuiescing else { return }
        precondition(desired.count <= capacity, "observing \(desired.count) threads exceeds the \(capacity) presenting screens")
        for (threadID, session) in desired {
            let subscription = subscriptions[threadID] ?? Subscription(threadID: threadID)
            subscriptions[threadID] = subscription
            if subscription.session === session { continue }
            subscription.session = session
            restart(subscription)
        }
        for subscription in Array(subscriptions.values) where subscription.session != nil && desired[subscription.threadID] == nil {
            subscription.session = nil
            restart(subscription)
        }
    }

    func connected(_ connection: UUID) { connectionID = connection; restartAll() }

    func disconnected() { connectionID = nil; restartAll() }

    func threadClosed(_ threadID: String, receipt: GatewayWireReceipt?) {
        guard let subscription = subscriptions[threadID], subscription.session != nil, let receipt,
              connectionID == receipt.connection else { return }
        guard let handle = subscription.handle else { subscription.pendingClosure = receipt; return }
        guard receipt.sequence > handle.sequence else { return }
        subscription.task?.cancel()
        subscription.generation = UUID()
        states[threadID] = .storedOnly
        let previous = subscription.task
        subscription.task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            try? await self.releaseHandle(of: subscription)
        }
    }

    func discoveredActiveThread(_ threadID: String) {
        if let subscription = subscriptions[threadID], subscription.session != nil, states[threadID] == .storedOnly {
            restart(subscription)
        }
    }

    func retry(threadID: String) {
        if let subscription = subscriptions[threadID] { restart(subscription) }
    }

    func quiesce() -> [Task<Void, Never>] {
        isQuiescing = true
        connectionID = nil
        for subscription in subscriptions.values {
            subscription.generation = UUID()
            subscription.task?.cancel()
        }
        return subscriptions.values.compactMap(\.task)
    }

    func finishQuiescing() async {
        for subscription in subscriptions.values {
            await subscription.task?.value
            subscription.task = nil
            if let handle = subscription.handle { await handle.session.cancelObservation(handle.capture) }
            subscription.handle = nil
        }
        states.removeAll()
    }

    func resume() { isQuiescing = false }

    func retire() async {
        isRetired = true
        connectionID = nil
        let retiring = Array(subscriptions.values)
        for subscription in retiring {
            subscription.session = nil
            subscription.generation = UUID()
            subscription.task?.cancel()
        }
        for subscription in retiring {
            await subscription.task?.value
            subscription.task = nil
            if let handle = subscription.handle { await handle.session.cancelObservation(handle.capture) }
            subscription.handle = nil
        }
        subscriptions.removeAll()
        states.removeAll()
    }

    private func restartAll() {
        for subscription in Array(subscriptions.values) { restart(subscription) }
    }

    private func releaseHandle(of subscription: Subscription) async throws {
        guard let released = subscription.handle else { return }
        try await gateway.closeSubscription(released.id, connection: released.connection)
        await released.session.cancelObservation(released.capture)
        if subscription.handle?.id == released.id && subscription.handle?.connection == released.connection {
            subscription.handle = nil
        }
    }

    private func restart(_ subscription: Subscription) {
        guard !isRetired, !isQuiescing else { return }
        let threadID = subscription.threadID
        let previous = subscription.task
        previous?.cancel()
        subscription.generation = UUID()
        let generation = subscription.generation
        states[threadID] = subscription.session == nil || connectionID == nil ? .detached : .attaching
        subscription.task = Task { [weak self] in
            await previous?.value
            guard let self, subscription.generation == generation else { return }
            do { try await self.releaseHandle(of: subscription) }
            catch {
                if subscription.generation == generation { self.states[threadID] = .failed(error.localizedDescription) }
                return
            }
            guard subscription.generation == generation else { return }
            guard let session = subscription.session else {
                if self.subscriptions[threadID] === subscription { self.subscriptions[threadID] = nil }
                self.states[threadID] = nil
                return
            }
            guard self.connectionID != nil else { return }
            for attempt in 0..<3 {
                guard !Task.isCancelled, subscription.generation == generation else { return }
                let capture = UUID()
                await session.beginObservation(capture)
                do {
                    self.states[threadID] = .attaching
                    let (response, receipt) = try await self.gateway.subscribe(threadID: threadID)
                    switch response {
                    case .notLoaded:
                        await session.cancelObservation(capture)
                        guard subscription.generation == generation, !Task.isCancelled else { return }
                        self.states[threadID] = .storedOnly
                        return
                    case .subscribed(let id, let wireThread, let checkpoint):
                        subscription.handle = (id, receipt.connection, receipt.sequence, capture, session)
                        try Task.checkCancellation()
                        if let closure = subscription.pendingClosure, closure.connection == receipt.connection, closure.sequence > receipt.sequence {
                            subscription.pendingClosure = nil
                            try await self.releaseHandle(of: subscription)
                            guard subscription.generation == generation, !Task.isCancelled else { return }
                            self.states[threadID] = .storedOnly
                            return
                        }
                        subscription.pendingClosure = nil
                        guard subscription.generation == generation else { throw CancellationError() }
                        let header = await ConversationHeader.prepare(wireThread)
                        guard subscription.generation == generation, !Task.isCancelled else { throw CancellationError() }
                        self.states[threadID] = .catchingUp
                        let read = await session.beginHistoryRead()
                        let pages = try await self.history.observationCheckpoint(header: header, checkpoint: checkpoint, previous: read.base)
                        try Task.checkCancellation()
                        guard subscription.generation == generation else { throw CancellationError() }
                        try await session.finishObservation(capture, receipt: receipt, header: header,
                            checkpoint: checkpoint, history: pages, read: read)
                        guard subscription.generation == generation, !Task.isCancelled else { return }
                        self.states[threadID] = .live
                        return
                    }
                } catch {
                    await session.cancelObservation(capture)
                    do { try await self.releaseHandle(of: subscription) }
                    catch {
                        if subscription.generation == generation { self.states[threadID] = .failed(error.localizedDescription) }
                        return
                    }
                    guard subscription.generation == generation, !Task.isCancelled else { return }
                    self.states[threadID] = .failed(error.localizedDescription)
                    guard attempt < 2 else { return }
                    do { try await Task.sleep(for: .seconds(attempt + 1)) } catch { return }
                }
            }
        }
    }
}
