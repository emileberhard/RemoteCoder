import Foundation

struct BrowserDictationRequest: Codable, Sendable {
    let operationId: String
    let path: String
    let deadlineUnixMs: Int64
}

struct BrowserDictationCancel: Codable, Sendable {
    let operationId: String
}

struct BrowserDictationOutput: Sendable {
    let text: String
    let model: String
}

struct BrowserDictationResult: Codable, Sendable {
    enum Outcome: String, Codable, Sendable { case succeeded, failed, cancelled }
    let operationId: String
    let outcome: Outcome
    var text: String?
    var model: String?
    var detail: String?
    var reason: String?
}

struct BrowserDictationConnection: Sendable {
    let host: BrowserDictationHost
    let enabled: @Sendable @MainActor () async -> Bool
    let execute: @Sendable (BrowserDictationRequest) async throws -> BrowserDictationOutput
}

actor BrowserDictationHost {
    private struct Operation {
        let id: String
        let generation: UUID
        let task: Task<Void, Never>
    }
    private var running: Operation?

    func invoke(_ request: BrowserDictationRequest, generation: UUID,
                execute: @escaping @Sendable (BrowserDictationRequest) async throws -> BrowserDictationOutput,
                deliver: @escaping @Sendable (BrowserDictationResult) async -> Void) -> BrowserDictationResult? {
        guard running?.id != request.operationId || running?.generation != generation else { return nil }
        guard running == nil else {
            return BrowserDictationResult(operationId: request.operationId, outcome: .failed, reason: "busy")
        }
        guard Int64(Date.now.timeIntervalSince1970 * 1000) < request.deadlineUnixMs else {
            return BrowserDictationResult(operationId: request.operationId, outcome: .failed, detail: "Deadline passed")
        }
        let task = Task { [self] in
            let result: BrowserDictationResult
            do {
                let output = try await execute(request)
                try Task.checkCancellation()
                result = BrowserDictationResult(operationId: request.operationId, outcome: .succeeded,
                                                text: output.text, model: output.model)
            } catch is CancellationError {
                result = BrowserDictationResult(operationId: request.operationId, outcome: .cancelled)
            } catch {
                result = BrowserDictationResult(operationId: request.operationId, outcome: .failed, detail: error.localizedDescription)
            }
            await deliver(result)
            if running?.id == request.operationId, running?.generation == generation { running = nil }
        }
        running = Operation(id: request.operationId, generation: generation, task: task)
        return nil
    }

    func cancel(_ cancel: BrowserDictationCancel, generation: UUID) {
        guard running?.id == cancel.operationId, running?.generation == generation else { return }
        running?.task.cancel()
    }

    func connectionLost(generation: UUID) async {
        guard let running, running.generation == generation else { return }
        running.task.cancel()
        await running.task.value
    }

    func waitUntilIdle() async {
        while let running { await running.task.value }
    }
}
