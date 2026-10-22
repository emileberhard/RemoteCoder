import Foundation

@MainActor
final class TerminationDrain {
    enum Presentation: Equatable {
        case finished([String])
        case pending
    }
    private let operation: Task<[String], Never>
    private var observer: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var result: [String]?
    private var waiter: CheckedContinuation<Presentation, Never>?

    init(_ operation: @escaping @MainActor () async -> [String]) {
        let task = Task { await operation() }
        self.operation = task
        observer = Task { [weak self] in
            let result = await task.value
            self?.completed(result)
        }
    }

    func presentation(after limit: Duration) async -> Presentation {
        if let result { return .finished(result) }
        return await withCheckedContinuation { continuation in
            precondition(waiter == nil)
            waiter = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: limit) } catch { return }
                self?.presentPending()
            }
        }
    }

    func drain() async -> [String] { await operation.value }

    private func completed(_ result: [String]) {
        self.result = result
        deadline?.cancel()
        deadline = nil
        waiter?.resume(returning: .finished(result))
        waiter = nil
        observer = nil
    }

    private func presentPending() {
        deadline = nil
        waiter?.resume(returning: .pending)
        waiter = nil
    }

    deinit {
        operation.cancel()
        observer?.cancel()
        deadline?.cancel()
    }
}
