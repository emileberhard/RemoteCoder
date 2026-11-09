import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationQueueTests: ConversationHistoryFixtures {
    private func queued(_ message: ChatMessage, as id: String) -> CodexAppServerV2.QueuedSubmission {
        CodexAppServerV2.QueuedSubmission(id: id, clientUserMessageId: message.id.uuidString)
    }

    private func listing(_ entries: [CodexAppServerV2.QueuedSubmission], hold: String? = nil) -> CodexAppServerV2.QueueListing {
        CodexAppServerV2.QueueListing(entries: entries, hold: hold.map(CodexAppServerV2.QueueHold.init(message:)))
    }

    private func user(_ message: ChatMessage, turnID: String, ordinal: Int) throws -> TurnScopedGatewayEvent {
        let id = message.id.uuidString
        return try GatewayEventFixture.item("item/completed",
            item: .userMessage(id: id, content: [.text(text: message.text, textElements: [])], clientId: id),
            threadID: "thread", turnID: turnID, ordinal: ordinal, startedAtMs: 1000 * ordinal, completedAtMs: 1000 * ordinal)
    }

    private func reply(_ text: String, turnID: String, ordinal: Int) throws -> TurnScopedGatewayEvent {
        try GatewayEventFixture.item("item/completed", item: .agentMessage(id: "reply-\(turnID)", text: text),
            threadID: "thread", turnID: turnID, ordinal: ordinal, startedAtMs: 1000 * ordinal, completedAtMs: 1000 * ordinal)
    }

    private func completed(_ turnID: String) throws -> TurnScopedGatewayEvent {
        try GatewayEventFixture.turn(.object(["threadId": .string("thread"),
            "turn": .object(["id": .string(turnID), "status": .string("completed")])]), method: "turn/completed")
    }

    private func runningState() throws -> ConversationState {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.activity(turnID: "turn", active: true)
        state.apply(try event("item/completed", item: .userMessage(id: "start", content: [.text(text: "Start", textElements: [])]), ordinal: 0))
        return state
    }

    @Test func queuedMessagesStayBelowTheWorkThatRunsBeforeThem() throws {
        var state = try runningState()
        let first = ChatMessage(role: .user, text: "First")
        let second = ChatMessage(role: .user, text: "Second")
        state.submitToQueue(first, input: first.text)
        state.submitToQueue(second, input: second.text)
        var memo = ConversationProjection.Memo()
        #expect(ConversationProjection.project(state, memo: &memo).messages.map(\.delivery) == [nil, .queueing, .queueing])

        state.queued(first.id, submission: queued(first, as: "q1"))
        state.queued(second.id, submission: queued(second, as: "q2"))
        let waiting = ConversationProjection.project(state, memo: &memo).messages
        #expect(waiting.map(\.text) == ["Start", "First", "Second"])
        #expect(waiting.map(\.delivery) == [nil, .queued, .queued])

        state.apply(try completed("turn"))
        state.apply(try user(first, turnID: "turn-first", ordinal: 1))
        state.apply(try reply("Working on first", turnID: "turn-first", ordinal: 2))
        let running = ConversationProjection.project(state, memo: &memo).messages
        #expect(running.map(\.text) == ["Start", "First", "Working on first", "Second"])
        #expect(running.map(\.delivery) == [nil, nil, nil, .queued])
        #expect(running[1].id == first.id)
        #expect(running.map(\.delivery) == ConversationProjection.project(state).messages.map(\.delivery))

        state.apply(try completed("turn-first"))
        state.apply(try user(second, turnID: "turn-second", ordinal: 3))
        let finished = ConversationProjection.project(state, memo: &memo).messages
        #expect(finished.map(\.text) == ["Start", "First", "Working on first", "Second"])
        #expect(finished.allSatisfy { $0.delivery == nil })
        #expect(state.submissions.isEmpty)
        #expect(!state.order.contains { ConversationState.isLocalTurnID($0) })
    }

    @Test func canonicalDeliveryBeforeTheQueueAcknowledgementWins() throws {
        var state = try runningState()
        let message = ChatMessage(role: .user, text: "Next")
        state.submitToQueue(message, input: message.text)
        state.apply(try completed("turn"))
        state.apply(try user(message, turnID: "turn-next", ordinal: 1))
        state.queued(message.id, submission: queued(message, as: "q1"))

        let messages = ConversationProjection.project(state).messages
        #expect(messages.map(\.text) == ["Start", "Next"])
        #expect(messages.map(\.delivery) == [nil, nil])
        #expect(state.submissions.isEmpty)
    }

    @Test func aRelaunchedReceiptIsUnconfirmedUntilTheQueueListsIt() throws {
        var state = try runningState()
        let message = ChatMessage(role: .user, text: "Later")
        state.submitToQueue(message, input: message.text)
        state.queued(message.id, submission: queued(message, as: "q1"))

        let saved = try JSONDecoder().decode(ConversationState.Checkpoint.self, from: JSONEncoder().encode(state.checkpoint))
        var restored = ConversationState(conversationID: state.conversationID, threadID: "thread")
        restored.restore(saved)
        #expect(ConversationProjection.project(restored).messages.last?.delivery == .unconfirmed)
        #expect(restored.queuedSubmissionID(for: message.id) == nil)
        #expect(restored.hasQueueReceipts)

        let read = restored.beginQueueRead()
        restored.applyQueue(listing([queued(message, as: "q1")]), read: read, threadIsIdle: false)
        #expect(ConversationProjection.project(restored).messages.last?.delivery == .queued)
        #expect(restored.queuedSubmissionID(for: message.id) == "q1")
    }

    @Test func absenceOnlyUnconfirmsAfterAnIdleReadThatStartedAfterTheReceipt() throws {
        var state = try runningState()
        let message = ChatMessage(role: .user, text: "Later")
        state.submitToQueue(message, input: message.text)
        let stale = state.beginQueueRead()
        state.queued(message.id, submission: queued(message, as: "q1"))

        state.applyQueue(listing([]), read: stale, threadIsIdle: true)
        #expect(ConversationProjection.project(state).messages.last?.delivery == .queued)

        let older = state.beginQueueRead()
        let busy = state.beginQueueRead()
        state.applyQueue(listing([]), read: busy, threadIsIdle: false)
        #expect(ConversationProjection.project(state).messages.last?.delivery == .queued)

        let idle = state.beginQueueRead()
        state.applyQueue(listing([]), read: idle, threadIsIdle: true)
        #expect(ConversationProjection.project(state).messages.last?.delivery == .unconfirmed)

        state.applyQueue(listing([queued(message, as: "q1")]), read: older, threadIsIdle: true)
        #expect(ConversationProjection.project(state).messages.last?.delivery == .unconfirmed)
    }

    @Test func aHeldQueueExplainsItselfOnceOnItsFirstLocalRowThatHasNoErrorOfItsOwn() throws {
        var state = try runningState()
        let first = ChatMessage(role: .user, text: "First")
        let second = ChatMessage(role: .user, text: "Second")
        let third = ChatMessage(role: .user, text: "Third")
        for (message, id) in [(first, "q1"), (second, "q2"), (third, "q3")] {
            state.submitToQueue(message, input: message.text)
            state.queued(message.id, submission: queued(message, as: id))
        }
        _ = state.queueActionFailed(first.id, reason: "Open in another client")
        let remote = CodexAppServerV2.QueuedSubmission(id: "q0", clientUserMessageId: "other-device")
        let entries = [remote, queued(first, as: "q1"), queued(second, as: "q2"), queued(third, as: "q3")]
        var memo = ConversationProjection.Memo()
        _ = ConversationProjection.project(state, memo: &memo)

        state.applyQueue(listing(entries, hold: "Start refused"), read: state.beginQueueRead(), threadIsIdle: true)
        let paused = ConversationProjection.project(state, memo: &memo).messages
        #expect(paused.map(\.delivery) == [nil, .queued, .queued, .queued])
        #expect(paused.map(\.deliveryError) == [nil, "Open in another client", "Paused: Start refused", nil])

        state.applyQueue(listing(entries), read: state.beginQueueRead(), threadIsIdle: false)
        #expect(ConversationProjection.project(state, memo: &memo).messages.map(\.deliveryError)
            == [nil, "Open in another client", nil, nil])
    }

    @Test func anUncertainAddIsConfirmedByItsClientMessageID() throws {
        var state = try runningState()
        let message = ChatMessage(role: .user, text: "Later")
        state.submitToQueue(message, input: message.text)
        state.submissionFailed(message.id, failure: .uncertain("The request timed out."))
        #expect(ConversationProjection.project(state).messages.last?.delivery == .unconfirmed)

        let read = state.beginQueueRead()
        state.applyQueue(listing([queued(message, as: "q7")]), read: read, threadIsIdle: false)
        #expect(ConversationProjection.project(state).messages.last?.delivery == .queued)
        #expect(state.queuedSubmissionID(for: message.id) == "q7")

        state.submissionFailed(message.id, failure: .rejected("Late failure"))
        #expect(ConversationProjection.project(state).messages.last?.delivery == .queued)
    }

    @Test func removingAQueuedMessageDropsItsRowAndPlaceholderTurn() throws {
        var state = try runningState()
        let message = ChatMessage(role: .user, text: "Later")
        state.submitToQueue(message, input: message.text)
        state.queued(message.id, submission: queued(message, as: "q1"))
        let removed = state.queueRemoved(message.id)

        #expect(removed)
        #expect(ConversationProjection.project(state).messages.map(\.text) == ["Start"])
        #expect(state.submissions.isEmpty)
        #expect(state.order == ["turn"])
    }

    @Test func aStartedQueuedMessageReadsAsTheFirstMessageOfItsTurn() throws {
        var state = try runningState()
        state.apply(try completed("turn"))
        let message = ChatMessage(role: .user, text: "Resume")
        state.submitToQueue(message, input: message.text)
        state.queued(message.id, submission: queued(message, as: "q1"))
        state.accepted(message.id, turnID: "turn-resumed")

        let messages = ConversationProjection.project(state).messages
        #expect(messages.map(\.text) == ["Start", "Resume"])
        #expect(messages.last?.delivery == nil)
        #expect(messages.last?.wasSteered == false)
        #expect(state.order == ["turn", "turn-resumed"])
    }

    @Test func aFailedQueueActionShowsWhyOnTheQueuedRow() throws {
        var state = try runningState()
        let message = ChatMessage(role: .user, text: "Later")
        state.submitToQueue(message, input: message.text)
        state.queued(message.id, submission: queued(message, as: "q1"))
        let recorded = state.queueActionFailed(message.id, reason: "Open in another client")
        #expect(recorded)

        let row = try #require(ConversationProjection.project(state).messages.last)
        #expect(row.delivery == .queued)
        #expect(row.deliveryError == "Open in another client")
    }

    @Test func aQueueAddConfirmedAfterATimeoutReturnsBelowNewerTurns() throws {
        var state = try runningState()
        let message = ChatMessage(role: .user, text: "Later")
        state.submitToQueue(message, input: message.text)
        state.submissionFailed(message.id, failure: .uncertain("Timed out"))
        state.apply(try completed("turn"))
        let other = ChatMessage(role: .user, text: "From another device")
        state.apply(try user(other, turnID: "turn-other", ordinal: 1))
        state.queued(message.id, submission: queued(message, as: "q1"))

        #expect(state.order == ["turn", "turn-other", ConversationState.localTurnID(message.id)])
    }
}
