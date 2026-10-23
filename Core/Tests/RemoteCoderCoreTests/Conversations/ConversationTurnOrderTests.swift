import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationTurnOrderTests: ConversationHistoryFixtures {
    private let turns = [(id: "t1", first: 0, last: 9), (id: "t2", first: 10, last: 19), (id: "t3", first: 20, last: 29)]

    private func turnID(_ ordinal: Int) -> String {
        turns.last { $0.first <= ordinal }?.id ?? "t1"
    }

    private func item(_ ordinal: Int) -> CodexAppServerV2.ThreadItem {
        turns.contains { $0.first == ordinal }
            ? .userMessage(id: "i\(ordinal)", content: [.text(text: "u\(ordinal)", textElements: [])], clientId: nil)
            : .agentMessage(id: "i\(ordinal)", text: "m\(ordinal)")
    }

    private func turnEvent(_ method: String, _ id: String, status: String) throws -> TurnScopedGatewayEvent {
        try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object([
            "id": .string(id), "status": .string(status)])]), method: method)
    }

    private func replay(_ state: inout ConversationState, _ ordinals: ClosedRange<Int>) throws {
        for ordinal in ordinals {
            let id = turnID(ordinal)
            if turns.contains(where: { $0.first == ordinal }) { state.apply(try turnEvent("turn/started", id, status: "inProgress"), replay: true) }
            state.apply(try GatewayEventFixture.item("item/completed", item: item(ordinal), threadID: "thread", turnID: id,
                ordinal: ordinal, startedAtMs: 1000 + ordinal, completedAtMs: 2000 + ordinal), replay: true)
            if id != "t3", turns.contains(where: { $0.last == ordinal }) {
                state.apply(try turnEvent("turn/completed", id, status: "completed"), replay: true)
            }
        }
    }

    private func tail(_ ordinals: ClosedRange<Int>) -> GatewayHistoryService.ConversationSnapshot {
        .fixture(wire: ordinals.reversed().map {
            .init(turnId: turnID($0), item: item($0), startedAtOrdinal: Int64($0), startedAtMs: Int64(1000 + $0), isComplete: true)
        }, turns: turns.reversed().map { summary($0.id, status: $0.id == "t3" ? .inProgress : .completed) },
           older: "c\(ordinals.lowerBound - 1)")
    }

    @Test func olderTurnsReplayedAfterTheTailNeverFollowTheLiveTurn() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        try replay(&state, 20...29)
        state.merge(tail(15...29))
        try replay(&state, 0...19)

        #expect(state.order == ["t2", "t3"])
        #expect(ConversationProjection.project(state).messages.last?.text == "m29")
    }

    @Test func restoringAMisorderedCheckpointPutsTheLiveTurnLast() throws {
        var saved = ConversationState(conversationID: UUID(), threadID: "thread")
        try replay(&saved, 0...29)
        let checkpoint = saved.checkpoint
        let misordered = ConversationState.Checkpoint(revision: checkpoint.revision, threadID: checkpoint.threadID,
            order: ["t2", "t3", "t1"], turns: checkpoint.turns, submissions: checkpoint.submissions, historyWindow: nil)

        var restored = ConversationState(conversationID: UUID(), threadID: "thread")
        restored.restore(misordered)

        #expect(restored.order == ["t1", "t2", "t3"])
        #expect(ConversationProjection.project(restored).messages.last?.text == "m29")
    }

    @Test func aQueuedMessageStaysLastWhenAnOlderTurnArrivesLate() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        try replay(&state, 10...19)
        let message = ChatMessage(role: .user, text: "Later")
        state.submitToQueue(message, input: message.text)
        try replay(&state, 0...9)

        #expect(state.order == ["t1", "t2", ConversationState.localTurnID(message.id)])
    }
}
