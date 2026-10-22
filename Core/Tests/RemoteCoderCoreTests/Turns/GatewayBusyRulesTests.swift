import Foundation
import Testing

@testable import RemoteCoderCore

struct GatewayBusyRulesTests {
    private typealias Fixture = ActiveTurnsFixture

    @Test func aRetiredSessionCarriesEveryExactJobItHeld() {
        let session = GatewayBusySession(
            sessionID: Fixture.codexThread,
            activeJobID: "gw-a-2",
            processingJobIDs: ["gw-a-1", "gw-a-2"]
        )
        #expect(
            TurnRegistry.decide(
                session,
                snapshot: Fixture.snapshot(),
                missingSince: Fixture.observed,
                observedAt: Fixture.confirmed
            ) == .retire(jobIDs: ["gw-a-1", "gw-a-2"], clearsActiveTurn: true)
        )
    }

    @Test func theOpenConversationWithAStreamLockIsRetiredAfterTheWindowLikeAnyOtherSession() {
        let session = GatewayBusySession(
            sessionID: Fixture.codexThread,
            activeJobID: "gw-a-1",
            processingJobIDs: ["gw-a-1"]
        )
        #expect(
            TurnRegistry.decide(
                session,
                snapshot: Fixture.snapshot(),
                missingSince: Fixture.observed,
                observedAt: Fixture.confirmed
            ) == .retire(jobIDs: ["gw-a-1"], clearsActiveTurn: true)
        )
    }

    @Test func aDispatchWithoutAJobIDYetIsNotEvidenceOfAnything() {
        let session = GatewayBusySession(
            sessionID: Fixture.codexThread,
            processingJobIDs: ["gw-a-1"],
            hasPendingDispatch: true
        )
        #expect(
            TurnRegistry.decide(
                session,
                snapshot: Fixture.snapshot(),
                missingSince: Fixture.observed,
                observedAt: Fixture.confirmed
            ) == .unknown
        )
    }

    @Test func aMissingTurnIsConfirmedOnlyAcrossTheWholeWindow() {
        #expect(TurnRegistry.missingObservation(since: nil, at: Fixture.observed) == .pending(since: Fixture.observed))
        #expect(
            TurnRegistry.missingObservation(since: Fixture.observed, at: Fixture.confirmed.addingTimeInterval(-0.001))
                == .pending(since: Fixture.observed)
        )
        #expect(TurnRegistry.missingObservation(since: Fixture.observed, at: Fixture.confirmed) == .confirmed)
    }

    @Test func tombstonesAreTurnExactAndBoundedPerThread() {
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

    @Test func jobIDsRoundTripBackToTheirTurn() {
        let thread = Fixture.codexThread
        let job = GatewayNotificationRouting.jobID(threadID: thread, turnID: "turn-4")
        #expect(GatewayNotificationRouting.normalizedTurnID(fromJobID: job, threadID: thread) == "4")
        #expect(GatewayNotificationRouting.normalizedTurnID(fromJobID: job, threadID: "other") == nil)
        #expect(GatewayNotificationRouting.normalizedTurnID(fromJobID: "gw-\(thread)-", threadID: thread) == nil)
    }

    @Test func aPushedSnapshotRoutesWithItsExactRevision() throws {
        let note = GatewayEventFixture.notification(
            method: "daemon/activeTurns/changed",
            params: .object([
                "epoch": .string("6f0f4b1e-2c1a-4f6e-9d55-0a1b2c3d4e5f"),
                "revision": .number(2),
                "generatedAtUnixSeconds": .number(1_790_330_861.099),
                "activeTurns": .array([.object([
                    "threadId": .string(Fixture.codexThread),
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
            receivedAt: Fixture.observed,
            sequence: nil
        )
        guard case .activity(let snapshot) = try #require(GatewayNotificationRouting.route(note)) else {
            Issue.record("expected an activity event")
            return
        }
        #expect(snapshot.revision == 2)
        #expect(snapshot.epoch == "6f0f4b1e-2c1a-4f6e-9d55-0a1b2c3d4e5f")
        #expect(snapshot.activeTurns.map(\.threadId) == [Fixture.codexThread])
    }
}
