import Foundation

actor HistoryReadScheduler {
    nonisolated enum Priority: Int, Sendable, Comparable {
        case foreground, reconciliation, prefetch

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    nonisolated struct Statistics: Sendable {
        let running: Int
        let pending: Int
        let waiters: Int
    }

    nonisolated struct Page: Sendable {
        let data: Data
        let startedAt: ContinuousClock.Instant
    }

    private enum Key: Hashable {
        case shared(HistoryPageKey)
        case fresh(HistoryPageKey, UUID)

        var page: HistoryPageKey {
            switch self {
            case .shared(let page), .fresh(let page, _): page
            }
        }
    }

    private struct Read {
        let id: UUID
        let sequence: UInt64
        var priority: Priority
        let operation: @Sendable () async throws -> Data
        var waiters: [UUID: CheckedContinuation<Page, any Error>]
        var task: Task<Void, Never>?
    }

    private struct Running {
        let hostID: String
        var priority: Priority
    }

    private var reads: [Key: Read] = [:]
    // Cancelled operations continue occupying a slot until their task actually ends.
    private var running: [UUID: Running] = [:]
    private var sequence: UInt64 = 0

    func read(
        key: HistoryPageKey,
        priority: Priority,
        operation: @escaping @Sendable () async throws -> Data
    ) async throws -> Page {
        try await read(key: .shared(key), priority: priority, operation: operation)
    }

    func readFresh(
        key: HistoryPageKey,
        priority: Priority,
        operation: @escaping @Sendable () async throws -> Data
    ) async throws -> Page {
        try await read(key: .fresh(key, UUID()), priority: priority, operation: operation)
    }

    private func read(
        key: Key,
        priority: Priority,
        operation: @escaping @Sendable () async throws -> Data
    ) async throws -> Page {
        let waiterID = UUID()
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    enqueue(key: key, waiterID: waiterID, priority: priority, operation: operation, continuation: continuation)
                }
            } onCancel: {
                Task { await self.cancelWaiter(key: key, waiterID: waiterID) }
            }
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    func invalidate(hostID: String) {
        invalidate { $0.page.hostID == hostID }
    }

    func invalidate(threadID: String, hostID: String) {
        invalidate { $0.page.hostID == hostID && $0.page.threadID == threadID }
    }

    func statistics(hostID: String) -> Statistics {
        let matching = reads.filter { $0.key.page.hostID == hostID }.values
        return Statistics(
            running: running.values.filter { $0.hostID == hostID }.count,
            pending: matching.filter { $0.task == nil }.count,
            waiters: matching.reduce(0) { $0 + $1.waiters.count }
        )
    }

    private func enqueue(
        key: Key,
        waiterID: UUID,
        priority: Priority,
        operation: @escaping @Sendable () async throws -> Data,
        continuation: CheckedContinuation<Page, any Error>
    ) {
        if var existing = reads[key] {
            existing.waiters[waiterID] = continuation
            existing.priority = min(existing.priority, priority)
            reads[key] = existing
            if running[existing.id] != nil { running[existing.id]?.priority = existing.priority }
        } else {
            sequence &+= 1
            reads[key] = Read(
                id: UUID(), sequence: sequence, priority: priority, operation: operation,
                waiters: [waiterID: continuation]
            )
        }
        startPendingReads()
    }

    private func startPendingReads() {
        let pending = reads.filter { $0.value.task == nil }.sorted {
            $0.value.priority != $1.value.priority
                ? $0.value.priority < $1.value.priority
                : $0.value.sequence < $1.value.sequence
        }
        for (key, _) in pending {
            guard var read = reads[key], read.task == nil else { continue }
            let hostRunning = running.values.filter { $0.hostID == key.page.hostID }
            guard hostRunning.count < 2 else { continue }
            if read.priority == .prefetch {
                guard !hostRunning.contains(where: { $0.priority == .prefetch }) else { continue }
                guard !reads.contains(where: {
                    $0.key.page.hostID == key.page.hostID && $0.value.task == nil && $0.value.priority != .prefetch
                }) else { continue }
            }
            let id = read.id
            let operation = read.operation
            running[id] = Running(hostID: key.page.hostID, priority: read.priority)
            read.task = Task(priority: read.priority == .prefetch ? .utility : .userInitiated) {
                let result: Result<Page, any Error>
                do {
                    try Task.checkCancellation()
                    let startedAt = ContinuousClock.now
                    let data = try await operation()
                    try Task.checkCancellation()
                    result = .success(Page(data: data, startedAt: startedAt))
                } catch {
                    result = .failure(error)
                }
                self.finish(key: key, id: id, result: result)
            }
            reads[key] = read
        }
    }

    private func finish(key: Key, id: UUID, result: Result<Page, any Error>) {
        running.removeValue(forKey: id)
        if let read = reads[key], read.id == id {
            reads.removeValue(forKey: key)
            for waiter in read.waiters.values { waiter.resume(with: result) }
        }
        startPendingReads()
    }

    private func cancelWaiter(key: Key, waiterID: UUID) {
        guard var read = reads[key], let waiter = read.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        if read.waiters.isEmpty {
            reads.removeValue(forKey: key)
            read.task?.cancel()
        } else {
            reads[key] = read
        }
        startPendingReads()
    }

    private func invalidate(matching predicate: (Key) -> Bool) {
        for key in Array(reads.keys).filter(predicate) {
            guard let read = reads.removeValue(forKey: key) else { continue }
            read.task?.cancel()
            for waiter in read.waiters.values { waiter.resume(throwing: HistoryReadFailure.invalidated) }
        }
        startPendingReads()
    }
}
