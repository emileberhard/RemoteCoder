import Foundation

actor HostFilePathAdmission {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let maximumWaiters: Int
    private var paths: [String: [Waiter]] = [:]
    private var waitingCount = 0

    init(maximumWaiters: Int = 24) { self.maximumWaiters = maximumWaiters }

    func acquire(_ path: String) async throws {
        try Task.checkCancellation()
        guard paths[path] != nil else {
            paths[path] = []
            return
        }
        guard waitingCount < maximumWaiters else { throw HostFileError.busy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                paths[path]?.append(Waiter(id: id, continuation: continuation))
                waitingCount += 1
            }
        } onCancel: {
            Task { await self.cancel(id, path: path) }
        }
    }

    func release(_ path: String) {
        guard var waiters = paths[path] else { return }
        guard !waiters.isEmpty else {
            paths.removeValue(forKey: path)
            return
        }
        let next = waiters.removeFirst()
        paths[path] = waiters
        waitingCount -= 1
        next.continuation.resume()
    }

    private func cancel(_ id: UUID, path: String) {
        guard let index = paths[path]?.firstIndex(where: { $0.id == id }),
              let waiter = paths[path]?.remove(at: index) else { return }
        waitingCount -= 1
        waiter.continuation.resume(throwing: CancellationError())
    }
}
