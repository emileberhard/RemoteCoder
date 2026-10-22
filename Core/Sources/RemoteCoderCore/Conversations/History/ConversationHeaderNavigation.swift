import Foundation

@MainActor
final class ConversationHeaderNavigation {
    private var reading: Task<Void, Never>?
    private let tasks = OwnedTasks<Bool>()

    @discardableResult
    func open(threadID: String, read: @escaping @MainActor (String) async throws -> ConversationHeader,
              present: @escaping @MainActor (ConversationHeader) -> Void,
              failed: @escaping @MainActor (any Error) -> Void) -> Task<Void, Never> {
        _ = cancel()
        let task = tasks.start(true) { [weak self] in
            do {
                let header = try await read(threadID)
                guard !Task.isCancelled, let self else { return }
                self.reading = nil
                present(header)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.reading = nil
                failed(error)
            }
        }
        reading = task
        return task
    }

    func quiesce() {
        tasks.quiesce()
        reading = nil
    }

    func drain() async { await tasks.drain() }

    func resume() { tasks.resume() }

    @discardableResult
    func cancel() -> [Task<Void, Never>] {
        guard let task = reading else { return [] }
        reading = nil
        task.cancel()
        return [task]
    }
}
