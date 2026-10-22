import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationCompactionTests: ConversationHistoryFixtures {
    @Test func slashCatalogDistinguishesCommandsFromPathsAndProse() {
        #expect(ComposerSlashCommand.parse(" /COMPACT \n") == .command(.compact))
        #expect(ComposerSlashCommand.parse("/compact extra") == .unexpectedArguments(.compact))
        #expect(ComposerSlashCommand.parse("/comp") == .incomplete)
        #expect(ComposerSlashCommand.parse("/unknown") == .unsupported("/unknown"))
        #expect(ComposerSlashCommand.parse("/Users/developer/project") == .message)
        #expect(ComposerSlashCommand.parse("Please /compact this") == .message)
        #expect(ComposerSlashCommand.suggestions(for: "/") == [.compact])
        #expect(ComposerSlashCommand.suggestions(for: "hello").isEmpty)
    }

    @Test func acknowledgmentDoesNotMeanDoneAndOnlyCanonicalItemCompletes() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let began1 = state.beginCompaction(UUID())
        #expect(began1)
        #expect(state.compaction?.phase == .requesting)
        let requested = try #require(ConversationProjection.project(state).items.first)
        guard case .compaction(let pending) = requested else { Issue.record("Missing requesting divider"); return }
        #expect(pending.compaction.phase == .requesting)
        let began2 = state.beginCompaction(UUID())
        #expect(!began2)
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object(["id": .string("turn"), "status": .string("inProgress")])]), method: "turn/started"))
        state.apply(try event("item/started", item: .contextCompaction(id: "compact"), ordinal: 1))
        #expect(state.compaction?.phase == .running)
        let running = ConversationProjection.project(state)
        #expect(running.compaction?.blocksSending == true)
        #expect(running.timelines.isEmpty, "Compaction is a transcript divider, not an agent activity group")
        #expect(running.items.count == 1, "The canonical item replaces the admission divider")
        let runningRow = try #require(running.items.first)
        guard case .compaction(let marker) = runningRow else { Issue.record("Missing running divider"); return }
        #expect(marker.compaction.phase == .running)
        state.apply(try event("item/completed", item: .contextCompaction(id: "compact"), ordinal: 1))
        #expect(state.compaction?.phase == .completed)
        #expect(state.compaction?.blocksSending == true)
        let completedRow = try #require(ConversationProjection.project(state).items.first)
        #expect(completedRow.id == runningRow.id)
        guard case .compaction(let completed) = completedRow else { Issue.record("Missing completed divider"); return }
        #expect(completed.compaction.phase == .completed)
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object(["id": .string("turn"), "status": .string("completed")])]), method: "turn/completed"))
        #expect(state.compaction?.blocksSending == false)
        #expect(ConversationProjection.project(state).items.count == 1, "A compaction turn must not show a no-reply outcome")
        state.submit(ChatMessage(role: .user, text: "Continue"))
        #expect(state.compaction == nil)
        #expect(ConversationProjection.project(state).items.first?.id == runningRow.id, "Sending keeps the completed divider")
    }

    @Test func automaticCompactionNeverBlocksSendingInsideAnActiveTurn() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object(["id": .string("turn"), "status": .string("inProgress")])]), method: "turn/started"))
        state.apply(try event("item/started", item: .contextCompaction(id: "automatic"), ordinal: 1))
        #expect(state.compaction?.requestID == nil)
        #expect(state.compaction?.phase == .running)
        #expect(state.compaction?.blocksSending == false)
        #expect(state.turns["turn"]?.terminal == false)
        state.activity(turnID: "turn", active: false)
        let inactiveRow = try #require(ConversationProjection.project(state).items.first)
        guard case .compaction(let inactive) = inactiveRow else { Issue.record("Missing inactive divider"); return }
        #expect(inactive.compaction.phase == .unconfirmed, "A retained live item must stop animating when activity confirms inactivity")
        state.activity(turnID: "turn", active: true)
        state.apply(try event("item/completed", item: .contextCompaction(id: "automatic"), ordinal: 1))
        #expect(state.compaction?.phase == .completed)
        #expect(state.compaction?.blocksSending == false)
        #expect(state.turns["turn"]?.terminal == false)
        #expect(ConversationProjection.project(state).timelines.last?.isLive == true,
            "Thinking resumes below the completed divider while the turn continues")
        state.apply(try event("item/started", item: .reasoning(id: "sampling", summary: [], content: []), ordinal: 2))
        #expect(ConversationProjection.project(state).timelines.last?.isLive == true,
            "An empty reasoning item must not hide the continuing turn")
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object(["id": .string("turn"), "status": .string("completed")])]), method: "turn/completed"))
        #expect(state.compaction?.turnFinished == true)
        #expect(state.compaction?.blocksSending == false)
        #expect(ConversationProjection.project(state).timelines.isEmpty)
    }

    @Test func unconfirmedAutomaticCompactionRemainsNonblockingAfterTheTurnEnds() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/started", item: .contextCompaction(id: "automatic"), ordinal: 1))
        state.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object(["id": .string("turn"), "status": .string("completed")])]), method: "turn/completed"))
        #expect(state.compaction?.phase == .unconfirmed)
        #expect(state.compaction?.turnFinished == true)
        #expect(state.compaction?.blocksSending == false)
        let row = try #require(ConversationProjection.project(state).items.first)
        guard case .compaction(let marker) = row else { Issue.record("Missing unconfirmed divider"); return }
        #expect(marker.compaction.phase == .unconfirmed)
    }

    @Test func historicalCompactionDoesNotPretendANewRequestFinished() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/completed", item: .contextCompaction(id: "old"), ordinal: 1), replay: true)
        #expect(state.compaction == nil)
        let began3 = state.beginCompaction(UUID())
        #expect(began3)
        state.apply(try event("item/completed", item: .contextCompaction(id: "old"), ordinal: 1), replay: true)
        #expect(state.compaction?.phase == .requesting)
    }

    @Test func lostResponseRemainsUnknownUntilHistoryConfirmsTheExactOperation() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let request = UUID()
        let began4 = state.beginCompaction(request)
        #expect(began4)
        state.compactionRequestFailed(request, message: "Disconnected", deliveryUncertain: true)
        #expect(state.compaction?.phase == .unconfirmed)
        state.clearFinishedCompaction()
        #expect(state.compaction?.blocksSending == true)
        state.merge(history(items: [.contextCompaction(id: "old")], turnID: "old", status: .completed))
        #expect(state.compaction?.phase == .unconfirmed)
        state.apply(try event("item/started", item: .contextCompaction(id: "compact"), ordinal: 1))
        state.merge(history(items: [.contextCompaction(id: "compact")], status: .completed))
        #expect(state.compaction?.phase == .completed)
        #expect(state.compaction?.turnID == "turn")
    }

    @Test func rejectedRequestRetainsAUsefulFailureAndAllowsRetry() {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let request = UUID()
        let began5 = state.beginCompaction(request)
        #expect(began5)
        state.compactionRequestFailed(UUID(), message: "Late other request", deliveryUncertain: false)
        #expect(state.compaction?.phase == .requesting)
        state.compactionRequestFailed(request, message: "Conversation is busy", deliveryUncertain: false)
        #expect(state.compaction?.phase == .failed("Conversation is busy"))
        let began6 = state.beginCompaction(UUID())
        #expect(began6)
    }
    @Test func confirmedIdleReleasesUncertainDeliveryWithoutClaimingCompletion() {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let request = UUID()
        _ = state.beginCompaction(request)
        state.compactionRequestFailed(request, message: "Disconnected", deliveryUncertain: true)
        state.compactionIdleConfirmed(requestID: request, turnID: nil)
        #expect(state.compaction?.blocksSending == false)
        #expect(state.compaction?.phase != .completed)
    }

    @Test func compactionSeparatesWorkOnEitherSideWithoutBecomingAnActivity() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(items: [
            .reasoning(id: "work-before", summary: ["Work before compaction"], content: []),
            .contextCompaction(id: "compact"),
            .reasoning(id: "work-after", summary: ["Work after compaction"], content: []),
        ], status: .completed))
        let snapshot = ConversationProjection.project(state)
        #expect(snapshot.items.count == 3)
        guard snapshot.items.count == 3 else { return }
        guard case .timeline(let before) = snapshot.items[0],
              case .compaction = snapshot.items[1],
              case .timeline(let after) = snapshot.items[2] else {
            Issue.record("The divider must split surrounding work into separate groups")
            return
        }
        #expect(before.events.count == 1)
        #expect(after.events.count == 1)
        #expect(before.events.first?.subtitle == "Work before compaction")
        #expect(after.events.first?.subtitle == "Work after compaction")
    }

    @Test func sequenceEpochResetKeepsExactTurnRecoveryAvailable() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        _ = state.beginCompaction(UUID())
        state.compactionSequence = 10_000
        state.resetEventSequences()
        #expect(state.compactionSequence == nil)
        state.apply(try event("item/started", item: .contextCompaction(id: "compact"), ordinal: 1))
        #expect(state.compaction?.phase == .running)
        #expect(state.compaction?.turnID == "turn")
    }

    @Test func nativeTransportUncertaintyIsTypedAndNeverAutomaticallyRetried() throws {
        let failure = try #require(GatewayRPCFailure(code: -32003, message: "Compaction outcome is unknown",
            data: .object(["kind": .string("compactionDeliveryUncertain"), "retryable": .bool(false), "threadId": .string("thread")])))
        #expect(failure.kind == .compactionDeliveryUncertain)
        #expect(!failure.retryable)
    }

    @Test func historyAndCheckpointsKeepEachDividerBetweenItsSurroundingReplies() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let items: [CodexAppServerV2.ThreadItem] = [
            .agentMessage(id: "before", text: "Before", phase: nil),
            .contextCompaction(id: "first"),
            .agentMessage(id: "between", text: "Between", phase: nil),
            .contextCompaction(id: "second"),
            .agentMessage(id: "after", text: "After", phase: nil),
        ]
        state.merge(history(items: items, status: .completed))
        let snapshot = ConversationProjection.project(state)
        #expect(snapshot.items.count == 5)
        #expect(snapshot.timelines.isEmpty)
        for (index, itemID) in [(1, "first"), (3, "second")] {
            guard case .compaction(let marker) = snapshot.items[index] else { Issue.record("Missing history divider at \(index)"); continue }
            #expect(marker.compaction.itemID == itemID)
            #expect(marker.compaction.phase == .completed)
        }
        // Repeated pages and reopening use canonical items, without transient status.
        state.merge(history(items: items, status: .completed))
        var reopened = ConversationState(conversationID: state.conversationID, threadID: "thread")
        reopened.restore(state.checkpoint)
        #expect(reopened.compaction == nil)
        #expect(ConversationProjection.project(reopened).items == snapshot.items)
    }

    @Test func staleInProgressHistoryDoesNotAnimateAnUnconfirmedCompaction() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let wire = CodexAppServerV2.ThreadItemsListResponse.Entry(turnId: "turn",
            item: .contextCompaction(id: "unfinished"), startedAtOrdinal: 0, startedAtMs: 1000, isComplete: false)
        state.merge(.fixture(threadID: "thread", wire: [wire], turns: [summary("turn")]))
        let row = try #require(ConversationProjection.project(state).items.first)
        guard case .compaction(let marker) = row else { Issue.record("Missing history divider"); return }
        #expect(marker.compaction.phase == .unconfirmed)
    }
}
