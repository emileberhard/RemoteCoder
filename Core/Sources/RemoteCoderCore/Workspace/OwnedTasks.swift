import Foundation

@MainActor
final class OwnedTasks<Key: Hashable> {
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var entries: [Key: Entry] = [:]
    private var acceptsWork = true
    private var running = 0
    private var drained: CheckedContinuation<Void, Never>?
    private var drainTask: Task<Void, Never>?

    func isRunning(_ key: Key) -> Bool { entries[key] != nil }

    func task(_ key: Key) -> Task<Void, Never>? { entries[key]?.task }

    @discardableResult
    func start(_ key: Key, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        launch(key, priority: nil, operation)
    }

    @discardableResult
    func startBackground(_ key: Key, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        launch(key, priority: .background, operation)
    }

    func value(_ key: Key) async {
        await task(key)?.value
    }

    func cancel(_ key: Key) {
        entries.removeValue(forKey: key)?.task.cancel()
    }

    @discardableResult
    func cancelAll() -> [Task<Void, Never>] {
        let running = entries.values.map(\.task)
        entries.removeAll()
        for task in running { task.cancel() }
        return running
    }

    func perform<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        guard acceptsWork else { throw CancellationError() }
        running += 1
        defer { completed() }
        return try await operation()
    }

    func quiesce() {
        acceptsWork = false
        cancelAll()
    }

    func drain() async {
        guard running > 0 else { return }
        let task = drainTask ?? Task {
            await withCheckedContinuation { continuation in
                if running == 0 { continuation.resume() }
                else { drained = continuation }
            }
        }
        drainTask = task
        await task.value
        if drainTask == task { drainTask = nil }
    }

    func resume() {
        precondition(running == 0)
        acceptsWork = true
    }

    private func launch(_ key: Key, priority: TaskPriority?, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        guard acceptsWork else { return Task {} }
        running += 1
        let id = UUID()
        entries[key]?.task.cancel()
        let task = Task(priority: priority) { [weak self] in
            await operation()
            self?.finish(key, id: id)
        }
        entries[key] = Entry(id: id, task: task)
        return task
    }

    private func finish(_ key: Key, id: UUID) {
        if entries[key]?.id == id { entries.removeValue(forKey: key) }
        completed()
    }

    private func completed() {
        running -= 1
        if running == 0 {
            drained?.resume()
            drained = nil
        }
    }
}
