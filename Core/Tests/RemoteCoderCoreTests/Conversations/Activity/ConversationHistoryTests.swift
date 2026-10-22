import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationHistoryTests {
    @Test func unknownOwnershipBlocksExistingSessionsIncludingColdLaunch() {
        var activity = ConversationActivity()
        #expect(activity.state(for: "claude_unseen") == .unknown)
        #expect(activity.dispatchBlock(for: "claude_unseen") == .unknown)
        #expect(activity.dispatchBlock(for: "codex_unseen") == .unknown)
        #expect(activity.dispatchBlock(for: nil) == nil)
        #expect(activity.dispatchBlock(for: "managed", hasManagedTurn: true) == nil)
        #expect(activity.state(for: "managed", hasManagedTurn: true) == .working)
        activity = ConversationActivity(snapshot: activitySnapshot(claudeAvailable: false))
        #expect(activity.dispatchBlock(for: "claude_unseen") == .unknown)
        #expect(activity.dispatchBlock(for: "codex_unseen") == nil)
        activity = ConversationActivity(snapshot: activitySnapshot())
        #expect(activity.state(for: "claude_unseen") == .idle)
        #expect(activity.dispatchBlock(for: "claude_unseen") == nil)
        activity = ConversationActivity(snapshot: activitySnapshot(claudeAvailable: false))
        #expect(activity.dispatchBlock(for: "claude_unseen") == .unknown)
    }

    @Test func managedSteeringAndExternalOwnershipHaveOneDispatchPolicy() {
        let active = CodexGatewayDaemon.ActiveTurn(
            threadId: "managed", turnId: "turn", startedAtUnixSeconds: 0, startedAtSequence: nil, promptPreview: "Test", cwd: nil
        )
        var activity = ConversationActivity(snapshot: activitySnapshot(
            sessions: [.init(threadId: "claude_external", state: .working, owner: nil)], active: [active]
        ))
        #expect(activity.dispatchBlock(for: "managed") == nil)
        #expect(activity.dispatchBlock(for: "claude_external") == .externalWork)
        #expect(activity.state(for: "claude_external") == .working)
        activity = ConversationActivity(snapshot: activitySnapshot(sessions: [.init(threadId: "claude_external", state: .waiting, owner: nil)]))
        #expect(activity.dispatchBlock(for: "claude_external") == .externalWork)
        #expect(activity.state(for: "claude_external") == .waiting)
        activity = ConversationActivity(snapshot: activitySnapshot(sessions: [.init(threadId: "claude_external", state: .idle, owner: nil)]))
        #expect(activity.dispatchBlock(for: "claude_external") == nil)
    }

    @Test func waitingSinceIsKnownOnlyWhileItsProviderIsCovered() {
        let parked = [CodexGatewayDaemon.ExternalActivity.SessionActivity(
            threadId: "claude_parked", state: .waiting, owner: nil, waitingSince: 1_785_900_000)]
        #expect(ConversationActivity(snapshot: activitySnapshot(sessions: parked)).waitingSince(for: "claude_parked") == 1_785_900_000)
        #expect(ConversationActivity(snapshot: activitySnapshot(sessions: parked, claudeAvailable: false))
            .waitingSince(for: "claude_parked") == nil)
        #expect(ConversationActivity().waitingSince(for: "claude_parked") == nil)
    }

    @Test func anySessionHeldByAnotherClientLocksUntilTakenOver() {
        var activity = ConversationActivity(snapshot: activitySnapshot(sessions: [
            .init(threadId: "claude_terminal", state: .idle, owner: .client),
            .init(threadId: "claude_warm", state: .working, owner: .gateway),
        ]))
        #expect(activity.dispatchBlock(for: "claude_terminal") == .otherClient)
        #expect(activity.dispatchBlock(for: "claude_terminal", hasManagedTurn: true) == nil)
        #expect(activity.dispatchBlock(for: "claude_warm") == nil)
        activity = ConversationActivity(snapshot: activitySnapshot(sessions: [
            .init(threadId: "claude_terminal", state: .unknown, owner: .client),
        ]))
        #expect(activity.dispatchBlock(for: "claude_terminal") == .otherClient)
    }

    @Test func childActivityDoesNotChangeParentExecutionAuthority() {
        var snapshot = activitySnapshot(sessions: [.init(threadId: "child", state: .working, owner: nil)])
        snapshot.agentOwners = ["child": "parent"]
        let activity = ConversationActivity(snapshot: snapshot)
        #expect(activity.state(for: "parent") == .working)
        #expect(activity.dispatchBlock(for: "parent") == nil)
        #expect(activity.dispatchBlock(for: "child") == .externalWork)
        #expect(activity.state(for: "unrelated") == .idle)
    }

    @Test func unavailableCodexInventoryCannotConfirmInactivity() {
        let snapshot = CodexGatewayDaemon.ActiveTurnsResponse(
            epoch: "epoch", revision: 1, activeTurns: [], coverage: .init(codex: false, claude: true),
            externalActivity: .init(sessions: [], claudeAvailable: false, codexAvailable: false), agentOwners: [:]
        )
        #expect(!snapshot.canConfirmInactivity(for: "codex_thread"))
        #expect(snapshot.canConfirmInactivity(for: "claude_thread"))
    }

    private func activitySnapshot(
        sessions: [CodexGatewayDaemon.ExternalActivity.SessionActivity] = [],
        active: [CodexGatewayDaemon.ActiveTurn] = [],
        claudeAvailable: Bool = true
    ) -> CodexGatewayDaemon.ActiveTurnsResponse {
        .init(epoch: "epoch", revision: 1, activeTurns: active, coverage: .init(codex: true, claude: true),
              externalActivity: .init(sessions: sessions, claudeAvailable: claudeAvailable, codexAvailable: true),
              agentOwners: [:])
    }
}
