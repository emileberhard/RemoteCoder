import Foundation

@MainActor
final class ConversationDraftNavigation {
    enum CarryOutcome: Equatable { case moved, retained, stopped }
    private struct Request {
        let destination: @MainActor () async -> Bool
        let carry: @MainActor () async -> CarryOutcome
    }

    private var pending: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var originalCarry: (@MainActor () async -> CarryOutcome)?
    private var carryingGeneration: UInt64?
    private var queued: Request?

    @discardableResult
    func retarget(_ destination: @escaping @MainActor () async -> Bool,
                  carry: @escaping @MainActor () async -> CarryOutcome) -> Task<Void, Never> {
        let request = Request(destination: destination, carry: carry)
        if carryingGeneration != nil {
            queued = request
            guard let pending else { preconditionFailure("A draft transfer has no owned task") }
            return pending
        }
        pending?.cancel()
        generation &+= 1
        if originalCarry == nil { originalCarry = carry }
        let current = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.navigate(request, generation: current)
        }
        pending = task
        return task
    }

    private func navigate(_ initial: Request, generation initialGeneration: UInt64) async {
        var request = initial
        var current = initialGeneration
        defer {
            if Task.isCancelled, generation == current {
                queued = nil
                originalCarry = nil
                pending = nil
                if carryingGeneration == current { carryingGeneration = nil }
            }
        }
        while true {
            guard !Task.isCancelled else { return }
            let committed = await request.destination()
            guard !Task.isCancelled, generation == current else { return }
            let outcome: CarryOutcome
            if committed {
                guard let originalCarry else { preconditionFailure("Navigation has no captured draft owner") }
                outcome = await originalCarry()
            } else { outcome = .retained }
            if carryingGeneration == current { carryingGeneration = nil }
            else { guard !Task.isCancelled, generation == current else { return } }
            if outcome == .moved { originalCarry = nil }
            if outcome == .stopped { queued = nil; originalCarry = nil; pending = nil; return }
            if Task.isCancelled { queued = nil; pending = nil; return }
            guard let next = queued else { originalCarry = nil; pending = nil; return }
            queued = nil
            if originalCarry == nil { originalCarry = next.carry }
            request = next
            generation &+= 1
            current = generation
        }
    }

    func commit(_ operation: @MainActor () async -> CarryOutcome) async -> CarryOutcome {
        guard !Task.isCancelled else { return .retained }
        precondition(carryingGeneration == nil)
        carryingGeneration = generation
        return await operation()
    }

    func cancel() {
        generation &+= 1
        queued = nil
        guard carryingGeneration == nil else { return }
        pending?.cancel()
        pending = nil
        originalCarry = nil
    }
}
