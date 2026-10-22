import Foundation
import Testing

@testable import RemoteCoderCore

@MainActor
struct TurnRegistryTests {
    private typealias Fixture = ActiveTurnsFixture
    private static let conversation = UUID(uuid: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private func jobID(_ thread: String, _ turn: String) -> String {
        GatewayNotificationRouting.jobID(threadID: thread, turnID: turn)
    }

    private func apply(
        _ registry: TurnRegistry,
        _ snapshot: CodexGatewayDaemon.ActiveTurnsResponse,
        at now: Date
    ) -> SnapshotOutcome {
        registry.apply(snapshot, observedAt: now)
    }

    @Test func anOrphanJobRetiresOnlyAfterStayingMissingForTheConfirmationWindow() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        _ = registry.register(Fixture.job(thread: thread, turn: "1"))
        #expect(registry.busyThreadIDs == [thread])

        _ = apply(registry, Fixture.snapshot(), at: Fixture.observed)
        _ = apply(registry, Fixture.snapshot(), at: Fixture.observed)
        #expect(registry.busyThreadIDs == [thread])

        let outcome = apply(registry, Fixture.snapshot(), at: Fixture.confirmed)

        #expect(registry.busyThreadIDs.isEmpty)
        #expect(registry.jobs.isEmpty)
        #expect(outcome.decisions == [
            SessionDecision(threadID: thread, decision: .retire(jobIDs: [jobID(thread, "1")], clearsActiveTurn: false)),
        ])
        #expect(outcome.change == TurnRegistryChange(countBefore: 1, countAfter: 0))
    }

    @Test func aTrackedTurnAndItsJobRetireTogether() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()

        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "1")]), at: Fixture.observed)
        #expect(registry.busyThreadIDs == [thread])
        #expect(registry.jobs.count == 1)

        _ = apply(registry, Fixture.snapshot(), at: Fixture.observed)
        #expect(registry.busyThreadIDs == [thread])
        _ = apply(registry, Fixture.snapshot(), at: Fixture.confirmed)

        #expect(registry.busyThreadIDs.isEmpty)
        #expect(registry.jobs.isEmpty)
        #expect(registry.turn(forThread: thread) == nil)
    }

    @Test func unknownCoverageNeverRetiresAndNeverAccumulatesConfirmations() {
        let codex = Fixture.codexThread
        let claude = Fixture.claudeThread
        let registry = TurnRegistry()
        _ = registry.register(Fixture.job(thread: codex, turn: "1"))
        _ = registry.register(Fixture.job(thread: claude, turn: "1"))

        let blind = Fixture.snapshot(codexCovered: false)
        _ = apply(registry, blind, at: Fixture.observed)
        _ = apply(registry, blind, at: Fixture.confirmed)
        #expect(registry.busyThreadIDs == [codex])

        let covered = Fixture.confirmed.addingTimeInterval(10)
        _ = apply(registry, Fixture.snapshot(), at: covered)
        #expect(registry.busyThreadIDs == [codex])
        _ = apply(registry, Fixture.snapshot(), at: covered.addingTimeInterval(TurnRegistry.confirmationWindow))
        #expect(registry.busyThreadIDs.isEmpty)
    }

    @Test func aServerReportedTurnIsNeverRetired() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        let active = Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "1")])

        for second in 0..<4 {
            _ = apply(registry, active, at: Fixture.observed.addingTimeInterval(Double(second)))
        }

        #expect(registry.busyThreadIDs == [thread])
        #expect(registry.jobs.count == 1)
    }

    @Test func anUnknownStartStaysUnknownWhileTheReportedTurnStaysActive() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        let active = Fixture.turn(thread: thread, id: "1", startedAt: nil, cwd: "/repo")

        _ = apply(registry, Fixture.snapshot(active: [active]), at: Fixture.observed)

        #expect(registry.busyThreadIDs == [thread])
        #expect(registry.jobs == [ActiveJob(id: jobID(thread, "1"), threadID: thread)])
    }

    @Test func aNewerReportedTurnReplacesTheOlderTurnAndItsJob() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()

        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "1")]), at: Fixture.observed)
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "2")]), at: Fixture.observed)

        #expect(registry.turn(forThread: thread)?.turnID == "2")
        #expect(registry.jobs.map(\.id) == [jobID(thread, "2")])
    }

    @Test func retiringAnOlderTurnLeavesTheNewerActiveTurnTracked() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "1")]), at: Fixture.observed)
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "2")]), at: Fixture.observed)

        _ = registry.retire(jobID: jobID(thread, "1"), threadID: thread, turnID: "1")

        #expect(registry.turn(forThread: thread)?.turnID == "2")
        #expect(registry.busyThreadIDs == [thread])
        #expect(registry.jobs.map(\.id) == [jobID(thread, "2")])
    }

    @Test func retiringTheTrackedTurnClearsBusyStateImmediately() {
        let thread = Fixture.claudeThread
        let registry = TurnRegistry()
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "7")]), at: Fixture.observed)
        #expect(registry.busyThreadIDs == [thread])

        let change = registry.retire(jobID: jobID(thread, "7"), threadID: thread, turnID: "7")

        #expect(registry.busyThreadIDs.isEmpty)
        #expect(registry.turn(forThread: thread) == nil)
        #expect(change == TurnRegistryChange(countBefore: 1, countAfter: 0))
    }

    @Test func aLateNotificationCannotReviveARetiredTurnButANewTurnStillOpens() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "1")]), at: Fixture.observed)
        _ = registry.retire(jobID: jobID(thread, "1"), threadID: thread, turnID: "1")
        #expect(registry.busyThreadIDs.isEmpty)

        #expect(registry.adopt(threadID: thread, turnID: "turn-1") == .ignored)
        #expect(registry.busyThreadIDs.isEmpty)

        let adoption = registry.adopt(threadID: thread, turnID: "turn-2")
        #expect(adoption == .adopted(TurnRegistryChange(countBefore: 0, countAfter: 1)))
        #expect(registry.busyThreadIDs == [thread])
        #expect(registry.jobs == [ActiveJob(id: jobID(thread, "2"), threadID: thread)])
    }

    @Test func aSnapshotDoesNotReviveARetiredTurn() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        _ = registry.retire(jobID: jobID(thread, "1"), threadID: thread, turnID: "1")

        let outcome = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "1")]), at: Fixture.observed)

        #expect(registry.busyThreadIDs.isEmpty)
        #expect(outcome.snapshot.activeTurns.isEmpty)
    }

    @Test func adoptingTheTrackedTurnAgainChangesNothingButForgetsAMissingObservation() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        #expect(registry.adopt(threadID: thread, turnID: "turn-3")
            == .adopted(TurnRegistryChange(countBefore: 0, countAfter: 1)))
        #expect(apply(registry, Fixture.snapshot(), at: Fixture.observed).decisions.map(\.decision) == [.pending(since: Fixture.observed)])

        #expect(registry.adopt(threadID: thread, turnID: "3") == .unchanged)

        #expect(apply(registry, Fixture.snapshot(), at: Fixture.confirmed).decisions.map(\.decision) == [.pending(since: Fixture.confirmed)])
    }

    @Test func aReplayBatchOfSixtyFourCompletionsKeepsEveryTurnTombstoned() {
        let thread = Fixture.claudeThread
        let registry = TurnRegistry()

        for turn in 1...64 {
            #expect(registry.complete(threadID: thread, turnID: "turn-\(turn)") != nil)
        }
        for turn in 1...64 {
            #expect(registry.complete(threadID: thread, turnID: "turn-\(turn)") == nil)
        }
        for turn in 1...64 {
            #expect(registry.adopt(threadID: thread, turnID: "turn-\(turn)") == .ignored)
        }

        #expect(registry.jobs.isEmpty)
        #expect(registry.busyThreadIDs.isEmpty)
    }

    @Test func aCompletionClearsOnlyTheTurnItNamed() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "2")]), at: Fixture.observed)

        let completion = registry.complete(threadID: thread, turnID: "turn-1")

        #expect(completion?.jobID == jobID(thread, "1"))
        #expect(registry.turn(forThread: thread)?.turnID == "2")
        #expect(registry.busyThreadIDs == [thread])
    }

    @Test func completingTheTrackedTurnReportsTheCountChange() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "5")]), at: Fixture.observed)

        let completion = registry.complete(threadID: thread, turnID: "turn-5")

        #expect(completion == CompletedTurn(
            threadID: thread,
            normalizedTurnID: "5",
            jobID: jobID(thread, "5"),
            change: TurnRegistryChange(countBefore: 1, countAfter: 0)
        ))
        #expect(registry.isIdle)
    }

    @Test func aDispatchThatHasNoJobYetIsNeverRetiredByASnapshot() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        _ = registry.lock(conversationID: Self.conversation, threadID: thread)
        _ = registry.register(Fixture.job(thread: thread, turn: "1"))

        _ = apply(registry, Fixture.snapshot(), at: Fixture.observed)
        let outcome = apply(registry, Fixture.snapshot(), at: Fixture.confirmed)

        #expect(outcome.decisions.map(\.decision) == [.unknown])
        #expect(registry.busyThreadIDs == [thread])
    }

    @Test func aDispatchIsPendingUntilItsLockIsReleasedThenTheAcceptedTurnRetires() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        let job = Fixture.job(thread: thread, turn: "1")
        _ = registry.lock(conversationID: Self.conversation, threadID: thread)
        _ = registry.acceptDispatch(
            job,
            turn: TrackedTurn(threadID: thread, turnID: "1", jobID: job.id),
            conversationID: Self.conversation
        )

        #expect(apply(registry, Fixture.snapshot(), at: Fixture.confirmed).decisions.map(\.decision) == [.unknown])

        _ = registry.unlock(conversationID: Self.conversation, threadID: thread)
        _ = apply(registry, Fixture.snapshot(), at: Fixture.observed)
        let outcome = apply(registry, Fixture.snapshot(), at: Fixture.confirmed)

        #expect(outcome.decisions.map(\.decision) == [.retire(jobIDs: [job.id], clearsActiveTurn: true)])
        #expect(registry.dispatchedTurn(id: job.id) == nil)
    }

    @Test func aDispatchedTurnKeepsItsFinalReplyUntilItFinishes() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        let job = Fixture.job(thread: thread, turn: "1")
        _ = registry.acceptDispatch(
            job,
            turn: TrackedTurn(threadID: thread, turnID: "1", jobID: job.id),
            conversationID: Self.conversation
        )

        registry.recordFinalReply("Done", jobID: job.id)
        registry.recordFinalReply("Ignored", jobID: "unknown")

        #expect(registry.finishDispatched(jobID: job.id)
            == DispatchedTurn(conversationID: Self.conversation, threadID: thread, turnID: "1", finalReply: "Done"))
        #expect(registry.dispatchedTurns.isEmpty)
    }

    @Test func theOpenConversationWithATrackedTurnIsRetiredAfterTheWindow() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "1")]), at: Fixture.observed)

        #expect(apply(registry, Fixture.snapshot(), at: Fixture.observed).decisions.map(\.decision) == [.pending(since: Fixture.observed)])
        let outcome = apply(registry, Fixture.snapshot(), at: Fixture.confirmed)

        #expect(outcome.decisions.map(\.decision) == [.retire(jobIDs: [jobID(thread, "1")], clearsActiveTurn: true)])
        #expect(registry.turn(forThread: thread) == nil)
    }

    @Test func clearingAnInterruptedTurnRemovesItsJobEvenWhenAnotherTurnIsTracked() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        _ = registry.register(Fixture.job(thread: thread, turn: "1"))
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "2")]), at: Fixture.observed)

        _ = registry.clearTurn(threadID: thread, turnID: "turn-1")

        #expect(registry.turn(forThread: thread)?.turnID == "2")
        #expect(registry.jobs.map(\.id) == [jobID(thread, "2")])

        _ = registry.clearTurn(threadID: thread, turnID: "2")

        #expect(registry.turn(forThread: thread) == nil)
        #expect(registry.jobs.isEmpty)
    }

    @Test func busyMeansAnyOfTheTrackedTurnTheJobsOrAnInflightDispatch() {
        let registry = TurnRegistry()
        let thread = Fixture.codexThread
        let other = Fixture.claudeThread
        #expect(!registry.isBusy(conversationID: Self.conversation, threadID: thread))

        _ = registry.lock(conversationID: Self.conversation, threadID: nil)
        #expect(registry.isBusy(conversationID: Self.conversation, threadID: nil))
        _ = registry.unlock(conversationID: Self.conversation, threadID: nil)
        #expect(registry.isIdle)

        _ = registry.lock(conversationID: UUID(), threadID: thread)
        #expect(registry.isBusy(conversationID: Self.conversation, threadID: thread))
        #expect(!registry.isBusy(conversationID: Self.conversation, threadID: other))

        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: other, id: "1")]), at: Fixture.observed)
        #expect(registry.isBusy(conversationID: Self.conversation, threadID: other))
        #expect(registry.busyThreadIDs == [thread, other])
    }

    @Test func nestedLocksReleaseOnlyWhenTheLastOneDoes() {
        let registry = TurnRegistry()
        let thread = Fixture.codexThread
        _ = registry.lock(conversationID: Self.conversation, threadID: thread)
        _ = registry.lock(conversationID: Self.conversation, threadID: thread)

        _ = registry.unlock(conversationID: Self.conversation, threadID: thread)
        #expect(registry.busyThreadIDs == [thread])
        #expect(!registry.isIdle)

        let change = registry.unlock(conversationID: Self.conversation, threadID: thread)
        #expect(registry.isIdle)
        #expect(change == TurnRegistryChange(countBefore: 1, countAfter: 0))

        _ = registry.unlock(conversationID: Self.conversation, threadID: thread)
        #expect(registry.isIdle)
    }

    @Test func aSubagentsWorkCountsAsItsOwnersWork() {
        let owner = Fixture.codexThread
        let subagent = "01a087fa-1348-7a93-8881-000000000001"
        let registry = TurnRegistry()

        _ = apply(
            registry,
            Fixture.snapshot(
                active: [
                    Fixture.turn(thread: owner, id: "1", startedAt: 1_788_995_000),
                    Fixture.turn(thread: subagent, id: "1", startedAt: 1_788_995_100),
                ],
                agentOwners: [subagent: owner]
            ),
            at: Fixture.observed
        )

        #expect(registry.liveActivityTaskCount == 1)
        #expect(registry.owner(ofThread: subagent) == owner)
        #expect(registry.busyThreadIDs == [owner, subagent])
    }

    @Test(arguments: [nil, CodexGatewayDaemon.ActiveTurnsResponse.OwnersCoverage.complete])
    func unavailableOwnershipRetainsGroupingUntilAnAuthoritativeRead(
        finalCoverage: CodexGatewayDaemon.ActiveTurnsResponse.OwnersCoverage?
    ) {
        let owner = Fixture.codexThread
        let child = Fixture.claudeThread
        let registry = TurnRegistry()
        let turns = [Fixture.turn(thread: owner, id: "1"), Fixture.turn(thread: child, id: "2")]
        _ = apply(registry, Fixture.snapshot(active: turns, agentOwners: [child: owner]), at: Fixture.observed)

        var unavailable = Fixture.snapshot(active: turns)
        unavailable.agentOwnersCoverage = .unavailable
        let outcome = registry.apply(unavailable, observedAt: Fixture.observed)

        #expect(registry.owner(ofThread: child) == owner)
        #expect(registry.liveActivityTaskCount == 1)
        #expect(outcome.snapshot.agentOwners == [child: owner])
        #expect(ConversationActivity(snapshot: outcome.snapshot).childThreadIDs(of: owner) == [child])

        var authoritative = Fixture.snapshot(active: turns)
        authoritative.agentOwnersCoverage = finalCoverage
        _ = apply(registry, authoritative, at: Fixture.observed)

        #expect(registry.owner(ofThread: child) == child)
        #expect(registry.liveActivityTaskCount == 2)
    }

    @Test func theTaskCountIsTheLargestOfTheFourBusySources() {
        let registry = TurnRegistry()
        _ = registry.lock(conversationID: UUID(), threadID: nil)
        _ = registry.lock(conversationID: UUID(), threadID: nil)
        _ = registry.register(Fixture.job(thread: Fixture.codexThread, turn: "1"))
        #expect(registry.liveActivityTaskCount == 2)

        _ = registry.register(Fixture.job(thread: Fixture.claudeThread, turn: "1"))
        _ = registry.register(ActiveJob(id: "gw-third", threadID: "third"))
        #expect(registry.liveActivityTaskCount == 3)
    }

    @Test(arguments: [
        (CodexGatewayDaemon.ActivityState.idle, CodexGatewayDaemon.ActivityState.idle, false),
        (.unknown, .unknown, false), (.working, .working, true), (.waiting, .working, true),
    ])
    func retainedOwnershipUsesTheChildsCurrentActivityDuringDiscoveryFailure(
        childState: CodexGatewayDaemon.ActivityState,
        parentState: CodexGatewayDaemon.ActivityState,
        parentIsKnownActive: Bool
    ) {
        let parent = Fixture.codexThread
        let child = Fixture.claudeThread
        let registry = TurnRegistry()
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: child, id: "1")],
            agentOwners: [child: parent]), at: Fixture.observed)
        _ = registry.complete(threadID: child, turnID: "1")
        let reported = CodexGatewayDaemon.ActiveTurnsResponse(
            epoch: "epoch", revision: 2, activeTurns: [], coverage: .init(codex: true, claude: true),
            externalActivity: .init(sessions: [
                .init(threadId: "claude_unclassified", state: .unknown, owner: nil),
            ] + (childState == .idle ? [] : [.init(threadId: child, state: childState, owner: nil)]),
                claudeAvailable: true, codexAvailable: true),
            agentOwners: [:], agentOwnersCoverage: .unavailable
        )
        let activity = ConversationActivity(snapshot: registry.apply(reported, observedAt: Fixture.observed).snapshot)

        #expect(activity.childThreadIDs(of: parent) == [child])
        #expect(activity.state(for: parent) == parentState)
        #expect(activity.knownActiveThreadIDs.contains(parent) == parentIsKnownActive)
    }

    @Test func aColdClientUsesPositiveOwnershipEvenWhenDiscoveryIsIncomplete() {
        let parent = Fixture.codexThread
        let child = Fixture.claudeThread
        let registry = TurnRegistry()
        var reported = Fixture.snapshot(active: [
            Fixture.turn(thread: parent, id: "1"), Fixture.turn(thread: child, id: "2"),
        ], agentOwners: [child: parent])
        reported.agentOwnersCoverage = .unavailable
        let outcome = registry.apply(reported, observedAt: Fixture.observed)

        #expect(registry.owner(ofThread: child) == parent)
        #expect(registry.liveActivityTaskCount == 1)
        #expect(ConversationActivity(snapshot: outcome.snapshot).childThreadIDs(of: parent) == [child])
    }

    @Test func aSteerIsCountedUntilItsLastAcknowledgement() {
        let registry = TurnRegistry()
        let thread = Fixture.codexThread
        registry.beginSteer(threadID: thread)
        registry.beginSteer(threadID: thread)

        registry.endSteer(threadID: thread)
        #expect(registry.isSteering(threadID: thread))
        registry.endSteer(threadID: thread)
        #expect(!registry.isSteering(threadID: thread))
    }

    @Test func aReplayOfAnActiveTurnIsClaimedOnceUntilItIsReleasedOrCompleted() {
        let thread = Fixture.claudeThread
        let registry = TurnRegistry()
        let job = jobID(thread, "1")

        #expect(registry.claimReplay(jobID: job))
        #expect(!registry.claimReplay(jobID: job))
        registry.releaseReplay(jobID: job)
        #expect(registry.claimReplay(jobID: job))

        _ = registry.complete(threadID: thread, turnID: "1")
        #expect(registry.claimReplay(jobID: job))
    }

    @Test func removingEverythingKeepsTheTombstonesAndTheInflightLocks() {
        let thread = Fixture.codexThread
        let registry = TurnRegistry()
        _ = registry.complete(threadID: thread, turnID: "1")
        _ = registry.lock(conversationID: Self.conversation, threadID: thread)
        _ = apply(registry, Fixture.snapshot(active: [Fixture.turn(thread: thread, id: "2")]), at: Fixture.observed)

        let change = registry.removeAll()

        #expect(registry.turn(forThread: thread) == nil)
        #expect(registry.jobs.isEmpty)
        #expect(registry.hasCompleted(threadID: thread, turnID: "turn-1"))
        #expect(registry.busyThreadIDs == [thread])
        #expect(change == TurnRegistryChange(countBefore: 1, countAfter: 1))
    }

    @Test func theRunningTurnsAreTheTrackedTurns() {
        let registry = TurnRegistry()
        _ = apply(
            registry,
            Fixture.snapshot(active: [
                Fixture.turn(thread: Fixture.codexThread, id: "turn-4"),
                Fixture.turn(thread: Fixture.claudeThread, id: "9"),
            ]),
            at: Fixture.observed
        )

        #expect(registry.runningTurns == [
            RunningTurn(threadID: Fixture.codexThread, turnID: "turn-4"),
            RunningTurn(threadID: Fixture.claudeThread, turnID: "9"),
        ])
        #expect(registry.trackedThreadIDs == [Fixture.codexThread, Fixture.claudeThread])
    }
}
