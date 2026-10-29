import Foundation

enum GatewayConnectionEvent: Sendable, Equatable {
    case connected(connection: UUID, route: GatewayRoute.Kind)
    case restarting
    case unreachable
    case disconnected
    case historyGap(threads: Set<String>, allThreads: Bool)
}

struct NotificationHub {
    private var continuations: [UUID: AsyncStream<CodexGatewayNotification>.Continuation] = [:]
    private var eventContinuations: [UUID: AsyncStream<GatewayConnectionEvent>.Continuation] = [:]
    private var replayFloor: UInt64?

    var streamCount: Int { continuations.count }

    mutating func add(_ continuation: AsyncStream<CodexGatewayNotification>.Continuation) -> UUID {
        let id = UUID()
        continuations[id] = continuation
        return id
    }

    mutating func remove(id: UUID) { continuations.removeValue(forKey: id) }

    mutating func addEventSubscriber(_ continuation: AsyncStream<GatewayConnectionEvent>.Continuation) -> UUID {
        let id = UUID()
        eventContinuations[id] = continuation
        return id
    }

    mutating func removeEventSubscriber(id: UUID) { eventContinuations.removeValue(forKey: id) }

    mutating func finishEvents() {
        let streams = eventContinuations
        eventContinuations.removeAll()
        for continuation in streams.values { continuation.finish() }
    }

    mutating func takeReplayFloor() -> UInt64? {
        defer { replayFloor = nil }
        return replayFloor
    }

    func emit(_ event: GatewayConnectionEvent) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    mutating func finishAll() {
        let streams = continuations
        continuations.removeAll()
        for continuation in streams.values { continuation.finish() }
    }

    mutating func publish(_ note: CodexGatewayNotification) -> Bool {
        var lostThreads: Set<String> = []
        var lostAllThreads = false
        var dropped = false
        for continuation in continuations.values {
            guard case .dropped(let lost) = continuation.yield(note) else { continue }
            dropped = true
            if let threadID = lost.params?.objectValue?["threadId"]?.stringValue { lostThreads.insert(threadID) }
            else { lostAllThreads = true }
            if let sequence = lost.sequence {
                self.replayFloor = min(self.replayFloor ?? sequence, sequence)
                // Finish after the buffered values so the pump restarts and
                // replays from before the dropped history entry.
                continuation.finish()
            }
        }
        if dropped { emit(.historyGap(threads: lostThreads, allThreads: lostAllThreads)) }
        return dropped
    }
}
