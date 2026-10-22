import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationStreamingContinuityTests: ConversationHistoryFixtures {
    enum TextKind: CaseIterable, Sendable {
        case answer, summary, reasoning, plan

        var method: String {
            switch self {
            case .answer: "item/agentMessage/delta"
            case .summary: "item/reasoning/summaryTextDelta"
            case .reasoning: "item/reasoning/textDelta"
            case .plan: "item/plan/delta"
            }
        }

        func item(_ text: String) -> CodexAppServerV2.ThreadItem {
            switch self {
            case .answer: .agentMessage(id: "item", text: text)
            case .summary: .reasoning(id: "item", summary: [text], content: [])
            case .reasoning: .reasoning(id: "item", summary: [], content: [text])
            case .plan: .plan(id: "item", text: text)
            }
        }

        func delta(_ text: String) throws -> TurnScopedGatewayEvent {
            try GatewayEventFixture.turn(method, params: ["threadId": .string("thread"), "turnId": .string("turn"),
                "itemId": .string("item"), "delta": .string(text), "summaryIndex": .number(0), "contentIndex": .number(0)])
        }
    }

    enum Coverage: CaseIterable, Sendable {
        case retained, restored, replayStarted, transportGap
    }

    @Test(arguments: TextKind.allCases, Coverage.allCases)
    func everyTextDeltaRequiresAContinuousPrefix(_ kind: TextKind, _ coverage: Coverage) throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/started", item: kind.item(""), ordinal: 1))
        state.apply(try kind.delta("A"))
        switch coverage {
        case .retained:
            state.apply(try kind.delta("B"))
        case .restored:
            let checkpoint = state.checkpoint
            state = ConversationState(conversationID: UUID(), threadID: "thread")
            state.restore(checkpoint)
        case .replayStarted:
            state = ConversationState(conversationID: UUID(), threadID: "thread")
            state.apply(try event("item/started", item: kind.item("A"), ordinal: 1), replay: true)
        case .transportGap:
            state.revokeStreamingPrefixes()
        }
        state.apply(try kind.delta("C"))
        #expect(state.turns["turn"]?.items["item"]?.value == kind.item(coverage == .retained ? "ABC" : "A"))
        #expect(state.turns["turn"]?.items["item"]?.completed == false)
        if coverage != .retained {
            state.apply(try event("item/started", item: kind.item("AB"), ordinal: 1))
            state.apply(try kind.delta("C"))
            #expect(state.turns["turn"]?.items["item"]?.value == kind.item("ABC"))
        }
        state.apply(try event("item/completed", item: kind.item("ABC"), ordinal: 1))
        #expect(state.turns["turn"]?.items["item"]?.value == kind.item("ABC"))
        #expect(state.turns["turn"]?.items["item"]?.completed == true)
    }

    @Test(arguments: TextKind.allCases)
    func aBufferedLiveStartCannotReplaceACompletedSnapshot(_ kind: TextKind) throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/completed", item: kind.item("ABC"), ordinal: 1), replay: true)
        state.apply(try event("item/started", item: kind.item(""), ordinal: 1))
        state.apply(try kind.delta("D"))
        #expect(state.turns["turn"]?.items["item"]?.value == kind.item("ABC"))
        state.merge(history(items: [kind.item("ABC")]))
        state.apply(try event("item/completed", item: kind.item("ABC"), ordinal: 1), replay: true)
        #expect(state.turns["turn"]?.items["item"]?.value == kind.item("ABC"))
        #expect(state.turns["turn"]?.items["item"]?.completed == true)
    }

    @Test(arguments: TextKind.allCases, [false, true])
    func anIncompleteHistoryRowCannotGrantOrReplaceALivePrefix(_ kind: TextKind, _ retainsPrefix: Bool) throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.apply(try event("item/started", item: kind.item("A"), ordinal: 1))
        if retainsPrefix {
            state.apply(try kind.delta("B"))
        } else {
            state.revokeStreamingPrefixes()
        }
        state.mergeObservation(header: .historyFixture(), checkpoint: .init(turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil, activeTurn: nil, historyUnavailable: true, liveItems: []),
            history: .init(turns: [], entries: [.init(turnId: "turn", item: kind.item("A"), isComplete: false)], update: nil),
            read: state.beginHistoryRead())
        state.apply(try kind.delta("C"))
        #expect(state.turns["turn"]?.items["item"]?.value == kind.item(retainsPrefix ? "ABC" : "A"))
        #expect(state.turns["turn"]?.items["item"]?.completed == false)
        #expect(state.turns["turn"]?.hasDiscardedLiveItems == true)
        state.apply(try event("item/completed", item: kind.item("ABC"), ordinal: 1))
        #expect(state.turns["turn"]?.items["item"]?.value == kind.item("ABC"))
        #expect(state.turns["turn"]?.items["item"]?.completed == true)
    }

    @Test func replacingAnUnknownPrefixEnforcesTheLiveByteBound() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(items: [], turnID: "loaded"))
        let text = String(repeating: "x", count: 3 * 1_024 * 1_024)
        state.apply(try event("item/started", item: .agentMessage(id: "older", text: text), ordinal: 0))
        state.apply(try event("item/started", item: .agentMessage(id: "item", text: "A"), ordinal: 1))
        state.revokeStreamingPrefixes()
        state.apply(try event("item/started", item: .agentMessage(id: "item", text: text), ordinal: 1))
        #expect(state.turns["turn"]?.order == ["item"])
        #expect(state.turns["turn"]?.hasDiscardedLiveItems == true)
    }
}
