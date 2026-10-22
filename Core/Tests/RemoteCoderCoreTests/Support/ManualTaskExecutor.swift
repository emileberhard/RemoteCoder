import Dispatch
import Foundation
import Synchronization

nonisolated final class ManualTaskExecutor: TaskExecutor {
    private enum Failure: Error { case notPaused, released, noJob }
    private struct State {
        var paused = false
        var jobs: [UnownedJob] = []
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "RemoteCoder.tests.manual-executor", qos: .utility)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let result = state.withLock { state -> (run: Bool, waiters: [CheckedContinuation<Void, any Error>]) in
            guard state.paused else { return (true, []) }
            precondition(state.jobs.count < 64)
            state.jobs.append(job)
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return (false, waiters)
        }
        for waiter in result.waiters { waiter.resume() }
        if result.run { queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) } }
    }

    func pause() { state.withLock { $0.paused = true } }

    func waitForJob() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock { state in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if !state.paused { continuation.resume(throwing: Failure.notPaused) }
                    else if !state.jobs.isEmpty { continuation.resume() }
                    else {
                        precondition(state.waiters.count < 64)
                        state.waiters[id] = continuation
                    }
                }
            }
        } onCancel: {
            self.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    func runNext() async throws {
        let job = try state.withLock { state in
            guard !state.jobs.isEmpty else { throw Failure.noJob }
            return state.jobs.removeFirst()
        }
        await withCheckedContinuation { continuation in
            queue.async {
                job.runSynchronously(on: self.asUnownedTaskExecutor())
                continuation.resume()
            }
        }
    }

    func resume() {
        let released = state.withLock { state in
            state.paused = false
            let jobs = state.jobs
            state.jobs.removeAll()
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return (jobs, waiters)
        }
        for waiter in released.1 { waiter.resume(throwing: Failure.released) }
        for job in released.0 { queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) } }
    }
}
