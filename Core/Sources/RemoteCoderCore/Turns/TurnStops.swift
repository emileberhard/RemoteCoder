import Foundation
import Observation

struct RunningTurn: Hashable, Sendable {
    let threadID: String
    let turnID: String
}

struct StopFailure: Equatable, Sendable {
    let threadID: String
    let message: String
}

protocol TurnInterrupting: Sendable {
    func interruptTurn(threadID: String, turnID: String) async throws
}

@MainActor @Observable
final class TurnStops {
    @ObservationIgnored private let gateway: any TurnInterrupting
    private var stopping: [String: Stopping] = [:]
    private(set) var failure: StopFailure?

    private struct Stopping: Equatable {
        let turnID: String
        var acknowledgedAt: Date?
    }

    init(gateway: any TurnInterrupting) {
        self.gateway = gateway
    }

    func isStopping(_ turn: RunningTurn) -> Bool {
        stopping[turn.threadID]?.turnID == turn.turnID
    }

    func stop(_ turn: RunningTurn) async throws {
        guard !isStopping(turn) else { return }
        stopping[turn.threadID] = Stopping(turnID: turn.turnID)
        if failure?.threadID == turn.threadID { failure = nil }
        do {
            try await gateway.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
            if isStopping(turn) { stopping[turn.threadID]?.acknowledgedAt = .now }
        } catch {
            if isStopping(turn) { stopping[turn.threadID] = nil }
            throw error
        }
    }

    func fail(_ turn: RunningTurn, message: String) {
        failure = StopFailure(threadID: turn.threadID, message: message)
    }

    func dismissFailure() {
        failure = nil
    }

    func retain(running: Set<RunningTurn>) {
        guard !stopping.isEmpty else { return }
        let kept = stopping.filter { running.contains(RunningTurn(threadID: $0.key, turnID: $0.value.turnID)) }
        if kept != stopping { stopping = kept }
    }

    func reopen(stillRunning running: Set<RunningTurn>, requestedAt: Date) {
        let kept = stopping.filter { threadID, stop in
            guard let acknowledgedAt = stop.acknowledgedAt, requestedAt > acknowledgedAt else { return true }
            return !running.contains(RunningTurn(threadID: threadID, turnID: stop.turnID))
        }
        if kept != stopping { stopping = kept }
    }
}
