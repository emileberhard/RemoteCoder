import Foundation
import Observation

@MainActor
@Observable
final class ExecutionTargetRegistry {
    private(set) var models: [ChatTargetModel] = []
    private struct Retirement {
        let model: ChatTargetModel
        let cleanup: @MainActor () async -> Bool
        let completion: @MainActor () -> Void
    }
    private struct RunningRetirement {
        let operation: Retirement
        let task: Task<Bool, Never>
    }
    private var retirements: [ExecutionTarget: RunningRetirement] = [:]
    private var failures: [ExecutionTarget: Retirement] = [:]

    func draftFailure(for selectedTarget: ExecutionTarget?) -> (target: ExecutionTarget, message: String)? {
        let preferred = selectedTarget.flatMap { failures[$0] == nil ? nil : $0 }
        guard let target = preferred ?? failures.keys.sorted(by: { $0.id < $1.id }).first,
              let model = failures[target]?.model, let message = model.drafts.errorMessage else { return nil }
        let identity = model.hostDisplayName
        return (target, "\(identity): \(message)")
    }

    var retiringModels: [ChatTargetModel] {
        var owners = failures.mapValues(\.model)
        for (target, running) in retirements { owners[target] = running.operation.model }
        return Array(owners.values)
    }

    func draftSaveForTermination(of target: ExecutionTarget) -> ChatTargetModel.TerminationDraftSave {
        if let running = retirements[target] { return .retirement(running.task) }
        if failures[target] != nil { return .failedRetirement }
        return .live
    }

    func model(for hostID: UUID) -> ChatTargetModel? {
        models.first { $0.hostID == hostID }
    }

    func routes(for host: GatewayHostConfiguration) -> GatewayRoutes? {
        model(for: host.id).flatMap { $0.host.hasSameConnection(as: host) ? $0.hostServices.routes : nil }
    }

    func isRetiring(_ target: ExecutionTarget) -> Bool {
        retirements[target] != nil || failures[target] != nil
    }

    func hasRunningRetirement(hostID: UUID) -> Bool {
        retirements.keys.contains { $0.hostID == hostID }
    }

    func replaceAll(with models: [ChatTargetModel]) {
        self.models = models
    }

    func retire(_ model: ChatTargetModel, cleanup: @escaping @MainActor () async -> Bool,
                completion: @escaping @MainActor () -> Void) {
        models.removeAll { $0 === model }
        start(Retirement(model: model, cleanup: cleanup, completion: completion))
    }

    func retry(_ target: ExecutionTarget) {
        guard retirements[target] == nil, let operation = failures[target] else { return }
        start(operation)
    }

    func isRetrying(_ target: ExecutionTarget) -> Bool {
        failures[target] != nil && retirements[target] != nil
    }

    private func start(_ operation: Retirement) {
        let target = operation.model.target
        let task = Task { [weak self] in
            let saved = await operation.cleanup()
            guard let self else { return saved }
            retirements[target] = nil
            if saved { failures[target] = nil; operation.completion() }
            else { failures[target] = operation }
            return saved
        }
        retirements[target] = RunningRetirement(operation: operation, task: task)
    }

    func awaitRetirements() async -> Bool {
        for running in Array(retirements.values) { _ = await running.task.value }
        return failures.isEmpty
    }
}
