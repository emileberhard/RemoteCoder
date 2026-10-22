import Foundation

@MainActor
final class TargetPreparation {
    private enum State {
        case unprepared, preparing(Task<Void, Never>), prepared, retired
    }
    private var state = State.unprepared

    var isPrepared: Bool {
        if case .prepared = state { true } else { false }
    }

    func prepare(_ operation: @escaping @MainActor () async -> Void) async {
        switch state {
        case .unprepared:
            let task = Task { await operation() }
            state = .preparing(task)
            await task.value
            guard case .preparing(let current) = state, current == task else { return }
            state = .prepared
        case .preparing(let task): await task.value
        case .prepared, .retired: return
        }
    }

    func quiesce() -> [Task<Void, Never>] {
        switch state {
        case .preparing(let task):
            state = .unprepared
            task.cancel()
            return [task]
        case .prepared:
            state = .unprepared
            return []
        case .unprepared, .retired: return []
        }
    }

    func retire() -> [Task<Void, Never>] {
        let tasks: [Task<Void, Never>]
        if case .preparing(let task) = state { tasks = [task] } else { tasks = [] }
        state = .retired
        for task in tasks { task.cancel() }
        return tasks
    }
}
