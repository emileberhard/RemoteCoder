import Testing
@testable import RemoteCoderCore

@MainActor
struct TurnStopTests {
    @Test func aRunningTurnOffersStopWhetherSendShowsWorkOrSteering() {
        let turn = RunningTurn(threadID: "claude_thread", turnID: "claude-turn-1")
        let stop = ComposerStopState(runningTurn: turn, isStopping: false)
        #expect(ComposerSendState(hasContent: false, isWorking: true, canSteer: true) == .working)
        let steering = ComposerSendState(hasContent: true, isWorking: true, canSteer: true)
        #expect(steering == .steer)
        #expect(steering.canSend)
        #expect(steering.accessibilityLabel == "Send steering message")
        #expect(stop == .ready(turn))
        #expect(ComposerStopState(runningTurn: nil, isStopping: false) == .hidden)
        #expect(!ComposerSendState(hasContent: true, isWorking: true, canSteer: false, isBlocked: true).canSend)
        #expect(ComposerSendState(hasContent: true, isWorking: false, canSteer: false) == .send)
    }

    @Test func stopInterruptsTheExactTurnOnceAndStaysStoppingUntilTheTurnEnds() async throws {
        let gateway = InterruptFixture()
        let stops = TurnStops(gateway: gateway)
        let turn = RunningTurn(threadID: "claude_thread", turnID: "claude-turn-2")
        let stop = Task { try await stops.stop(turn) }
        await gateway.waitForRequests(1)
        #expect(ComposerStopState(runningTurn: turn, isStopping: stops.isStopping(turn)) == .stopping)
        try await stops.stop(turn)
        await gateway.answer(accepting: true)
        try await stop.value

        stops.retain(running: [turn])
        #expect(stops.isStopping(turn))
        stops.retain(running: [RunningTurn(threadID: "claude_thread", turnID: "claude-turn-3")])
        #expect(!stops.isStopping(turn))
        #expect(await gateway.requests == [turn])
    }

    @Test func aRefusedStopReachesTheCallerAndLeavesTheTurnStoppable() async {
        let gateway = InterruptFixture()
        let stops = TurnStops(gateway: gateway)
        let turn = RunningTurn(threadID: "codex-thread", turnID: "turn-7")
        let stop = Task { try await stops.stop(turn) }
        await gateway.waitForRequests(1)
        await gateway.answer(accepting: false)

        await #expect(throws: InterruptRefusal.self) { try await stop.value }
        #expect(ComposerStopState(runningTurn: turn, isStopping: stops.isStopping(turn)) == .ready(turn))
    }

    @Test func aLateRefusalForAnEndedTurnKeepsTheNextTurnStopping() async throws {
        let gateway = InterruptFixture()
        let stops = TurnStops(gateway: gateway)
        let ended = RunningTurn(threadID: "codex-thread", turnID: "turn-1")
        let next = RunningTurn(threadID: "codex-thread", turnID: "turn-2")
        let endedStop = Task { try await stops.stop(ended) }
        await gateway.waitForRequests(1)
        stops.retain(running: [next])
        let nextStop = Task { try await stops.stop(next) }
        await gateway.waitForRequests(2)

        await gateway.answer(accepting: false)
        _ = await endedStop.result
        #expect(stops.isStopping(next))
        await gateway.answer(accepting: true)
        try await nextStop.value
        #expect(await gateway.requests == [ended, next])
    }

    @Test func anAcknowledgedStopReopensOnlyWhenALaterReadStillShowsTheTurn() async throws {
        let gateway = InterruptFixture()
        let stops = TurnStops(gateway: gateway)
        let turn = RunningTurn(threadID: "codex-thread", turnID: "turn-4")
        let stop = Task { try await stops.stop(turn) }
        await gateway.waitForRequests(1)
        stops.reopen(stillRunning: [turn], requestedAt: .distantFuture)
        #expect(stops.isStopping(turn))
        await gateway.answer(accepting: true)
        try await stop.value

        stops.reopen(stillRunning: [turn], requestedAt: .distantPast)
        #expect(stops.isStopping(turn))
        stops.reopen(stillRunning: [], requestedAt: .distantFuture)
        #expect(stops.isStopping(turn))
        stops.reopen(stillRunning: [turn], requestedAt: .distantFuture)
        #expect(ComposerStopState(runningTurn: turn, isStopping: stops.isStopping(turn)) == .ready(turn))
    }

    @Test func aStopFailureStaysWithItsConversationUntilItsNextStop() async throws {
        let gateway = InterruptFixture()
        let stops = TurnStops(gateway: gateway)
        let failed = RunningTurn(threadID: "claude_thread", turnID: "claude-turn-5")
        let other = RunningTurn(threadID: "codex-thread", turnID: "turn-8")
        stops.fail(failed, message: "The Stop could not be saved.")

        let otherStop = Task { try await stops.stop(other) }
        await gateway.waitForRequests(1)
        await gateway.answer(accepting: true)
        try await otherStop.value
        #expect(stops.failure == StopFailure(threadID: "claude_thread", message: "The Stop could not be saved."))

        let retry = Task { try await stops.stop(failed) }
        await gateway.waitForRequests(2)
        #expect(stops.failure == nil)
        await gateway.answer(accepting: true)
        try await retry.value
    }
}

private struct InterruptRefusal: Error {}

private actor InterruptFixture: TurnInterrupting {
    private(set) var requests: [RunningTurn] = []
    private var replies: [CheckedContinuation<Bool, Never>] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func interruptTurn(threadID: String, turnID: String) async throws {
        requests.append(RunningTurn(threadID: threadID, turnID: turnID))
        let ready = requestWaiters.filter { $0.count <= requests.count }
        requestWaiters.removeAll { $0.count <= requests.count }
        ready.forEach { $0.continuation.resume() }
        let accepted = await withCheckedContinuation { replies.append($0) }
        if !accepted { throw InterruptRefusal() }
    }

    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func answer(accepting: Bool) {
        replies.removeFirst().resume(returning: accepting)
    }
}
