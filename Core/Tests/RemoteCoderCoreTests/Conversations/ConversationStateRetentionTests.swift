import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationStateRetentionTests {
    @Test(arguments: [false, true])
    func completedMessagesSurviveAnOlderWindowAndTheNextTurn(steering: Bool) throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let older = history(turnID: "older", entries: [])
        state.merge(older)
        try start("recent", in: &state)
        if steering {
            try deliver(.userMessage(id: "original", content: [.text(text: "Start", textElements: [])]), turnID: "recent", in: &state)
        }
        let message = ChatMessage(role: .user, text: "Keep this message",
                                  wasSteered: steering, canonicalTurnID: steering ? "recent" : nil)
        state.submit(message)
        state.accepted(message.id, turnID: "recent")
        let user = canonical(message)
        try deliver(user, turnID: "recent", in: &state)
        try deliver(.agentMessage(id: "reply", text: "Done"), turnID: "recent", in: &state)
        #expect(state.submissions.isEmpty)
        let before = visibleIDs(state, turnID: "recent")
        #expect(before == (steering ? ["original"] : []) + [user.id, "reply"])
        try finish("recent", in: &state)
        #expect(visibleIDs(state, turnID: "recent") == before)
        state.merge(older)
        try start("next", in: &state)
        try deliver(.agentMessage(id: "next-reply", text: "Working"), turnID: "next", in: &state)
        #expect(visibleIDs(state, turnID: "recent") == before)
        #expect(state.turns["recent"]?.items[user.id]?.localMessage?.id == message.id)

        var restored = ConversationState(conversationID: state.conversationID, threadID: "thread")
        restored.restore(state.checkpoint)
        #expect(visibleIDs(restored, turnID: "recent") == before)
    }

    @Test(arguments: [false, true], [2000, 3000] as [Int64])
    func aDelayedCompletionReplacesOnlyAnOlderLiveRecord(previouslyComplete: Bool, completedAt: Int64) throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(turnID: "older", entries: []))
        try deliver(.agentMessage(id: "reply", text: "Live"), turnID: "recent", complete: previouslyComplete, in: &state)
        let delayed = history(turnID: "recent", entries: [
            .init(turnId: "recent", item: .agentMessage(id: "reply", text: "Final"), completedAtMs: completedAt, isComplete: true)
        ])
        state.merge(delayed)
        #expect(state.window?.turns.map(\.id) == ["recent"])
        #expect(visibleIDs(state, turnID: "recent") == ["reply"])
        if case .agentMessage(_, let text, _, _, _) = state.turns["recent"]?.items["reply"]?.value {
            #expect(text == (previouslyComplete && completedAt == 2000 ? "Live" : "Final"))
        } else { Issue.record("The delayed completion must remain available") }
        #expect((state.turns["recent"]?.items["reply"]?.encodedBytes ?? 0) > 0)
    }

    @Test func anAcknowledgingTailPreservesTheSubmittedMessage() {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(turnID: "older", entries: []))
        let message = ChatMessage(role: .user, text: "Acknowledged by history")
        state.submit(message)
        state.accepted(message.id, turnID: "recent")
        let user = canonical(message)
        state.merge(history(turnID: "recent", entries: [
            .init(turnId: "recent", item: user, completedAtMs: 2000, isComplete: true)
        ]))
        #expect(state.submissions.isEmpty)
        #expect(visibleIDs(state, turnID: "recent") == [user.id])
        #expect(state.turns["recent"]?.items[user.id]?.localMessage?.id == message.id)
    }

    @Test(arguments: [nil, 1000, 2000, 3000] as [Int64?])
    func onlyAnAdoptedCurrentCompletionTransfersRetention(completedAt: Int64?) throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let item = CodexAppServerV2.ThreadItem.agentMessage(id: "reply", text: "Live result")
        try deliver(item, turnID: "recent", in: &state)
        state.merge(history(turnID: "recent", entries: [
            .init(turnId: "recent", item: item, completedAtMs: completedAt, isComplete: true)
        ]))
        #expect(visibleIDs(state, turnID: "recent") == ["reply"])
        state.merge(history(turnID: "older", entries: []))
        let historyOwnsCompletion = completedAt.map { $0 >= 2000 } ?? false
        #expect(visibleIDs(state, turnID: "recent") == (historyOwnsCompletion ? [] : ["reply"]))
    }

    @Test func theRecentTailIsBoundedWhileLoadedActiveAndLocalTurnsSurvive() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(turnID: "loaded", entries: [
            .init(turnId: "loaded", item: .agentMessage(id: "loaded-reply", text: "Loaded"), isComplete: true)
        ]))
        try start("active", in: &state)
        let pending = ChatMessage(role: .user, text: "Pending")
        state.submit(pending)
        state.accepted(pending.id, turnID: "pending")
        state.appendLocal(ChatMessage(role: .codex, text: "Local record"), turnID: "local")
        for index in 0..<40 {
            let id = "recent-\(index)"
            try start(id, in: &state)
            let message = ChatMessage(role: .user, text: "Message \(index)")
            state.submit(message)
            state.accepted(message.id, turnID: id)
            try deliver(canonical(message), turnID: id, in: &state)
            try finish(id, in: &state)
        }
        #expect(Set(state.turns.keys) == Set((8..<40).map { "recent-\($0)" } + ["loaded", "active", "pending", "local"]))
        #expect(state.turns["recent-39"]?.items.count == 1)
        #expect(Set(state.submissions.keys) == [pending.id])
    }

    @Test func streamingGrowthDefersTheByteBoundToTheNextItem() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(turnID: "loaded", entries: []))
        for index in 0..<205 {
            try delta("Start", item: "reply-\(index)", in: &state)
        }
        #expect(state.turns["live"]?.order == (5..<205).map { "reply-\($0)" })
        let chunk = String(repeating: "é", count: 128 * 1024)
        for _ in 0..<17 { try delta(chunk, item: "reply-204", in: &state) }
        #expect(state.turns["live"]?.order.count == 200)
        if case .agentMessage(_, let text, _, _, _) = state.turns["live"]?.items["reply-204"]?.value {
            #expect(text == "Start" + String(repeating: chunk, count: 17))
        } else { Issue.record("The growing item must keep every delta") }
        try delta("Next", item: "reply-205", in: &state)
        #expect(state.turns["live"]?.order == ["reply-205"])
        #expect(state.turns["live"]?.hasDiscardedLiveItems == true)
    }

    private func delta(_ text: String, item: String, in state: inout ConversationState) throws {
        if state.turns["live"]?.items[item] == nil {
            try apply("item/started", params: ["turnId": .string("live"),
                "item": .object(["type": .string("agentMessage"), "id": .string(item), "text": .string("")])], in: &state)
        }
        try apply("item/agentMessage/delta", params: ["turnId": .string("live"), "itemId": .string(item),
            "delta": .string(text)], in: &state)
    }

    private func visibleIDs(_ state: ConversationState, turnID: String) -> [String] {
        state.turns[turnID].map { state.visibleItems(in: $0) } ?? []
    }

    private func canonical(_ message: ChatMessage) -> CodexAppServerV2.ThreadItem {
        .userMessage(id: "canonical-\(message.id)", content: [.text(text: message.text, textElements: [])], clientId: message.id.uuidString)
    }

    private func start(_ turnID: String, in state: inout ConversationState) throws {
        try apply("turn/started", params: ["turn": .object(["id": .string(turnID), "status": .string("inProgress")])], in: &state)
    }

    private func finish(_ turnID: String, in state: inout ConversationState) throws {
        try apply("turn/completed", params: ["turn": .object(["id": .string(turnID), "status": .string("completed")])], in: &state)
    }

    private func deliver(_ item: CodexAppServerV2.ThreadItem, turnID: String, complete: Bool = true, in state: inout ConversationState) throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))
        try apply(complete ? "item/completed" : "item/started", params: ["turnId": .string(turnID), "item": raw,
            "completedAtMs": .number(2000)], in: &state)
    }

    private func apply(_ method: String, params: [String: JSONValue], in state: inout ConversationState) throws {
        let params = params.merging(["threadId": .string("thread")]) { _, new in new }
        state.apply(try GatewayEventFixture.turn(method, params: params, receivedAt: .now))
    }

    private func history(turnID: String, entries: [CodexAppServerV2.ThreadItemsListResponse.Entry]) -> GatewayHistoryService.ConversationSnapshot {
        .fixture(wire: entries.reversed(), turns: [.init(id: turnID, items: [], startedAt: 1,
            completedAt: 2, status: .completed, error: nil)])
    }

}
