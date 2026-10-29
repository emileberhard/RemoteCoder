import Foundation
import Testing
@testable import RemoteCoder

/// Regressions for the history drawer showing "Working" after a session
/// finished. Runtime authority is the daemon's active-turn snapshot; local
/// processing rows and active-turn entries must both yield to it, and a
/// finished turn must never erase a newer turn's state.
struct GatewayBusyStateTests {
    private static let codexThread = "01a087fa-1348-7a93-8881-4b406d7bbc8b"
    private static let claudeThread = "claude_01a087fa-1348-7a93-8881-4b406d7bbc8b"
    private static let observed = Date(timeIntervalSince1970: 1_788_995_200)
    private static let confirmed = observed.addingTimeInterval(TurnRegistry.confirmationWindow)

    // MARK: - Production reconciliation

    @MainActor
    @Test func orphanProcessingRowRetiresOnlyAfterStayingMissingForTheConfirmationWindow() async throws {
        let thread = Self.codexThread
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        _ = model.target.turns.register(job(thread: thread, turn: "1"))

        #expect(model.target.historyBusySessionIDs.contains(thread))
        model.target.reconcileWithDaemonActiveTurns(snapshot(), observedAt: Self.observed)
        model.target.reconcileWithDaemonActiveTurns(snapshot(), observedAt: Self.observed)
        #expect(model.target.historyBusySessionIDs.contains(thread))
        model.target.reconcileWithDaemonActiveTurns(snapshot(), observedAt: Self.confirmed)
        #expect(model.target.historyBusySessionIDs.isEmpty)
        #expect(model.target.turns.jobs.isEmpty)
    }

    @MainActor
    @Test func trackedActiveTurnAndItsProcessingRowRetireTogether() async throws {
        let thread = Self.codexThread
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)

        model.target.reconcileWithDaemonActiveTurns(snapshot(active: [turn(thread: thread, id: "1")]), observedAt: Self.observed)
        #expect(model.target.historyBusySessionIDs == [thread])
        #expect(model.target.turns.jobs.count == 1)

        model.target.reconcileWithDaemonActiveTurns(snapshot(), observedAt: Self.observed)
        #expect(model.target.historyBusySessionIDs == [thread])
        model.target.reconcileWithDaemonActiveTurns(snapshot(), observedAt: Self.confirmed)
        #expect(model.target.historyBusySessionIDs.isEmpty)
        #expect(model.target.turns.jobs.isEmpty)
    }

    @MainActor
    @Test func unknownCoverageNeverRetiresAndNeverAccumulatesConfirmations() async throws {
        let codex = Self.codexThread
        let claude = Self.claudeThread
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        _ = model.target.turns.register(job(thread: codex, turn: "1"))
        _ = model.target.turns.register(job(thread: claude, turn: "1"))

        // Claude coverage is independent of the Codex app-server inventory, so
        // the same snapshot confirms one thread and not the other.
        let blind = snapshot(codexCovered: false)
        model.target.reconcileWithDaemonActiveTurns(blind, observedAt: Self.observed)
        model.target.reconcileWithDaemonActiveTurns(blind, observedAt: Self.confirmed)
        #expect(model.target.historyBusySessionIDs == [codex])

        // Coverage returning must still wait out a confirmation window of its own.
        let covered = Self.confirmed.addingTimeInterval(10)
        model.target.reconcileWithDaemonActiveTurns(snapshot(), observedAt: covered)
        #expect(model.target.historyBusySessionIDs == [codex])
        model.target.reconcileWithDaemonActiveTurns(snapshot(), observedAt: covered.addingTimeInterval(TurnRegistry.confirmationWindow))
        #expect(model.target.historyBusySessionIDs.isEmpty)
    }

    @MainActor
    @Test func aServerReportedTurnIsNeverRetired() async throws {
        let thread = Self.codexThread
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let active = snapshot(active: [turn(thread: thread, id: "1")])

        for second in 0..<4 { model.target.reconcileWithDaemonActiveTurns(active, observedAt: Self.observed.addingTimeInterval(Double(second))) }
        #expect(model.target.historyBusySessionIDs == [thread])
        #expect(model.target.turns.jobs.count == 1)
    }

    @MainActor
    @Test func unknownStartStillKeepsTheReportedTurnActive() async throws {
        let thread = Self.codexThread
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let active = CodexGatewayDaemon.ActiveTurn(threadId: thread, turnId: "1",
            startedAtUnixSeconds: nil, startedAtSequence: nil, promptPreview: "Working", cwd: "/repo")

        model.target.reconcileWithDaemonActiveTurns(snapshot(active: [active]), observedAt: Self.observed)

        #expect(model.target.historyBusySessionIDs == [thread])
    }

    // MARK: - Exact-job retirement

    @MainActor
    @Test func retiringAnOlderTurnLeavesTheNewerActiveTurnSteerable() async throws {
        let thread = Self.codexThread
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)

        // A turn starts, then a newer turn replaces it on the same thread.
        model.target.reconcileWithDaemonActiveTurns(snapshot(active: [turn(thread: thread, id: "1")]), observedAt: Self.observed)
        model.target.reconcileWithDaemonActiveTurns(snapshot(active: [turn(thread: thread, id: "2")]), observedAt: Self.observed)

        // The first turn's stream now finishes. It must not clear turn 2.
        model.target.retireGatewayJob(
            threadID: thread,
            turnID: "1",
            jobID: jobID(thread: thread, turn: "1")
        )

        model.setActiveSessionID(thread)
        #expect(model.canSteerCurrentConversation)
        #expect(model.target.historyBusySessionIDs == [thread])
        #expect(model.target.turns.jobs.map(\.id) == [jobID(thread: thread, turn: "2")])
    }

    @MainActor
    @Test func retiringTheTrackedTurnClearsBusyStateImmediately() async throws {
        let thread = Self.claudeThread
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        model.target.reconcileWithDaemonActiveTurns(snapshot(active: [turn(thread: thread, id: "7")]), observedAt: Self.observed)
        #expect(model.target.historyBusySessionIDs == [thread])

        model.target.retireGatewayJob(
            threadID: thread,
            turnID: "7",
            jobID: jobID(thread: thread, turn: "7")
        )

        model.setActiveSessionID(thread)
        #expect(model.target.historyBusySessionIDs.isEmpty)
        #expect(!model.canSteerCurrentConversation)
    }

    // MARK: - Replay cannot revive a retired job

    @MainActor
    @Test func aLateNotificationCannotReviveARetiredTurnButANewTurnStillOpens() async throws {
        let thread = Self.codexThread
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        model.target.reconcileWithDaemonActiveTurns(snapshot(active: [turn(thread: thread, id: "1")]), observedAt: Self.observed)
        model.target.retireGatewayJob(
            threadID: thread,
            turnID: "1",
            jobID: jobID(thread: thread, turn: "1")
        )
        #expect(model.target.historyBusySessionIDs.isEmpty)

        // Replayed history for the turn we just retired.
        await applyItemStarted(model, thread: thread, turn: "turn-1")
        #expect(model.target.historyBusySessionIDs.isEmpty)

        // The tombstone is turn-exact: a genuinely new turn still opens.
        await applyItemStarted(model, thread: thread, turn: "turn-2")
        #expect(model.target.historyBusySessionIDs == [thread])
    }

    @MainActor
    @Test func aReplayBatchOfSixtyFourCompletionsKeepsEveryTurnTombstoned() async throws {
        let thread = Self.claudeThread
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let completions = (1...64).map { turnCompleted(thread: thread, turn: "turn-\($0)") }

        for completion in completions {
            await model.target.apply(gatewayEvent: completion)
        }
        for completion in completions {
            await model.target.apply(gatewayEvent: completion, replay: true)
        }
        for turn in 1...64 {
            await applyItemStarted(model, thread: thread, turn: "turn-\(turn)")
        }

        #expect(model.target.turns.jobs.isEmpty)
        #expect(model.target.historyBusySessionIDs.isEmpty)
    }

    // MARK: - Over the wire

    @MainActor
    @Test(.timeLimit(.minutes(1))) func aTurnTheGatewayReportsKeepsItsThreadBusyAndSteersOnTheWire() async throws {
        let gateway = try FakeGatewayServer(threadID: Self.claudeThread, model: "opus")
        await gateway.reportActiveTurn("turn-running")
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let workspace = fixture.workspace
        let chat = try #require(workspace.selectedScreen)
        await chat.target.conversationList.record(ConversationHeader(try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: Data(#"""
            {"id":"\#(Self.claudeThread)","preview":"Test","modelProvider":"anthropic","model":"opus","createdAt":0,
             "updatedAt":1,"cwd":"/repo","cliVersion":"test","source":"appServer","status":{"type":"notLoaded"},
             "ephemeral":false,"turns":[]}
            """#.utf8))))
        workspace.selectConversation(at: .init(hostID: fixture.mini.id, threadID: Self.claudeThread))
        Task { await chat.target.prepareIfNeeded() }
        try #require(await waitUntil { chat.canSteerCurrentConversation })
        #expect(chat.target.historyBusySessionIDs.contains(Self.claudeThread))

        #expect(await chat.prepareDraft())
        chat.input = "Keep going"
        #expect(await workspace.send(from: chat))

        #expect(await waitUntil { await gateway.steers == [.init(threadID: Self.claudeThread, text: "Keep going")] })
        let steer = try #require(await gateway.requests("turn/steer").first?.objectValue)
        #expect(steer["expectedTurnId"]?.stringValue == "turn-running")
        #expect(await gateway.turnStarts.isEmpty)
    }

    // MARK: - Decision rules

    @Test func aRetiredSessionCarriesEveryExactJobItHeld() async {
        let session = GatewayBusySession(
            sessionID: Self.codexThread,
            activeJobID: "gw-a-2",
            processingJobIDs: ["gw-a-1", "gw-a-2"]
        )
        #expect(
            TurnRegistry.decide(
                session,
                snapshot: snapshot(),
                missingSince: Self.observed,
                observedAt: Self.confirmed
            ) == .retire(jobIDs: ["gw-a-1", "gw-a-2"], clearsActiveTurn: true)
        )
    }

    @Test func theOpenConversationWithAStreamLockIsRetiredAfterTheWindowLikeAnyOtherSession() async {
        let session = GatewayBusySession(
            sessionID: Self.codexThread,
            activeJobID: "gw-a-1",
            processingJobIDs: ["gw-a-1"]
        )
        #expect(
            TurnRegistry.decide(
                session,
                snapshot: snapshot(),
                missingSince: Self.observed,
                observedAt: Self.confirmed
            ) == .retire(jobIDs: ["gw-a-1"], clearsActiveTurn: true)
        )
    }

    @Test func aDispatchWithoutAJobIDYetIsNotEvidenceOfAnything() async {
        let session = GatewayBusySession(
            sessionID: Self.codexThread,
            processingJobIDs: ["gw-a-1"],
            hasPendingDispatch: true
        )
        #expect(
            TurnRegistry.decide(
                session,
                snapshot: snapshot(),
                missingSince: Self.observed,
                observedAt: Self.confirmed
            ) == .unknown
        )
    }

    @Test func aMissingTurnIsConfirmedOnlyAcrossTheWholeWindow() async {
        #expect(TurnRegistry.missingObservation(since: nil, at: Self.observed) == .pending(since: Self.observed))
        #expect(
            TurnRegistry.missingObservation(since: Self.observed, at: Self.confirmed.addingTimeInterval(-0.001))
                == .pending(since: Self.observed)
        )
        #expect(TurnRegistry.missingObservation(since: Self.observed, at: Self.confirmed) == .confirmed)
    }

    // MARK: - Pushed snapshots

    @Test func aPushedSnapshotRoutesWithItsExactRevision() async throws {
        let note = GatewayEventFixture.notification(
            method: "daemon/activeTurns/changed",
            params: .object([
                "epoch": .string("6f0f4b1e-2c1a-4f6e-9d55-0a1b2c3d4e5f"),
                "revision": .number(2),
                "generatedAtUnixSeconds": .number(1_790_330_861.099),
                "activeTurns": .array([.object([
                    "threadId": .string(Self.codexThread),
                    "turnId": .string("4"),
                    "startedAtUnixSeconds": .number(1_790_330_800),
                    "lastSeenAtUnixSeconds": .number(1_790_330_800),
                    "promptPreview": .string("hey"),
                    "cwd": .null,
                    "source": .string("gateway"),
                ])]),
                "coverage": .object(["codex": .bool(true), "claude": .bool(true)]),
                "externalActivity": .object([
                    "sessions": .array([]),
                    "claudeAvailable": .bool(true),
                    "codexAvailable": .bool(true),
                ]),
                "agentOwners": .object([:]),
            ]),
            receivedAt: Self.observed,
            sequence: nil
        )
        guard case .activity(let snapshot) = try #require(GatewayNotificationRouting.route(note)) else {
            Issue.record("expected an activity event")
            return
        }
        #expect(snapshot.revision == 2)
        #expect(snapshot.epoch == "6f0f4b1e-2c1a-4f6e-9d55-0a1b2c3d4e5f")
        #expect(snapshot.activeTurns.map(\.threadId) == [Self.codexThread])
    }

    @MainActor
    @Test func anOlderSnapshotCannotReplaceANewerOne() async throws {
        let thread = Self.codexThread
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)

        model.target.applyActivity(snapshot(revision: 5), observedAt: .now)
        model.target.applyActivity(snapshot(revision: 4, active: [turn(thread: thread, id: "1")]), observedAt: .now)
        #expect(model.target.historyBusySessionIDs.isEmpty)

        model.target.applyActivity(snapshot(revision: 6, active: [turn(thread: thread, id: "1")]), observedAt: .now)
        #expect(model.target.historyBusySessionIDs == [thread])
    }

    @Test func tombstonesAreTurnExactAndBoundedPerThread() async {
        var tombstones = CompletedTurnTombstones(limitPerThread: 2)
        tombstones.record(threadID: "a", normalizedTurnID: "1")
        tombstones.record(threadID: "a", normalizedTurnID: "1")
        tombstones.record(threadID: "a", normalizedTurnID: "2")
        #expect(tombstones.contains(threadID: "a", normalizedTurnID: "1"))
        #expect(!tombstones.contains(threadID: "b", normalizedTurnID: "1"))

        tombstones.record(threadID: "a", normalizedTurnID: "3")
        #expect(!tombstones.contains(threadID: "a", normalizedTurnID: "1"))
        #expect(tombstones.contains(threadID: "a", normalizedTurnID: "3"))
    }

    @Test func jobIDsRoundTripBackToTheirTurn() async {
        let thread = Self.codexThread
        let job = GatewayNotificationRouting.jobID(threadID: thread, turnID: "turn-4")
        #expect(GatewayNotificationRouting.normalizedTurnID(fromJobID: job, threadID: thread) == "4")
        #expect(GatewayNotificationRouting.normalizedTurnID(fromJobID: job, threadID: "other") == nil)
        #expect(GatewayNotificationRouting.normalizedTurnID(fromJobID: "gw-\(thread)-", threadID: thread) == nil)
    }

    // MARK: - Helpers

    private func jobID(thread: String, turn: String) -> String {
        GatewayNotificationRouting.jobID(threadID: thread, turnID: turn)
    }

    private func job(thread: String, turn: String) -> ActiveJob {
        ActiveJob(id: jobID(thread: thread, turn: turn), threadID: thread)
    }

    private func turn(thread: String, id: String) -> CodexGatewayDaemon.ActiveTurn {
        CodexGatewayDaemon.ActiveTurn(
            threadId: thread,
            turnId: id,
            startedAtUnixSeconds: 1_788_995_000,
            startedAtSequence: nil,
            promptPreview: "hey! u know the ai inspo meeting",
            cwd: "/Users/developer/RemoteCoder"
        )
    }

    private func snapshot(
        revision: UInt64 = 1,
        active: [CodexGatewayDaemon.ActiveTurn] = [],
        codexCovered: Bool = true
    ) -> CodexGatewayDaemon.ActiveTurnsResponse {
        CodexGatewayDaemon.ActiveTurnsResponse(
            epoch: "epoch",
            revision: revision,
            activeTurns: active,
            coverage: .init(codex: codexCovered, claude: true),
            externalActivity: .init(sessions: [], claudeAvailable: true, codexAvailable: true),
            agentOwners: [:]
        )
    }

    private func turnCompleted(thread: String, turn: String) -> RoutedGatewayEvent {
        guard let event = GatewayEventFixture.route("turn/completed", params: [
            "threadId": .string(thread), "turnId": .string(turn),
            "turn": .object(["id": .string(turn), "status": .string("completed")])
        ], receivedAt: .now) else {
            fatalError("turn/completed did not route")
        }
        return event
    }

    @MainActor
    private func applyItemStarted(_ model: ChatScreenModel, thread: String, turn: String) async {
        let note = GatewayEventFixture.notification(
            method: "item/started",
            params: .object([
                "threadId": .string(thread),
                "turnId": .string(turn),
            ])
        )
        guard let event = GatewayNotificationRouting.route(note) else {
            Issue.record("item/started did not route")
            return
        }
        await model.target.apply(gatewayEvent: event)
    }
}
