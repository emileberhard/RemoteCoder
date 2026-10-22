import Foundation
import Testing
@testable import RemoteCoderCore

struct HistoryPresentationTests {
    private func entry(_ id: String, turn: String) -> CodexAppServerV2.ThreadItemsListResponse.Entry {
        .init(turnId: turn, item: .agentMessage(id: id, text: id), isComplete: true)
    }

    private func turn(_ id: String) -> CodexAppServerV2.Turn {
        .init(id: id, items: [], startedAt: 1, completedAt: 2, status: .completed, error: nil)
    }

    private func edges(_ state: ConversationState) -> [String] {
        ConversationProjection.project(state).items.map(\.id).filter { $0.hasPrefix("history-edge") }
    }

    @Test func edgeRowsMarkOnlyTheWindowsOpenEnds() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: [entry("b1", turn: "b"), entry("a1", turn: "a")], turns: [turn("b"), turn("a")], older: "before-a1"))
        #expect(ConversationProjection.project(state).items.first?.id == "history-edge-older")
        #expect(edges(state) == ["history-edge-older"])

        let window = try #require(state.window)
        state.merge(.fixture(wire: [entry("a0", turn: "a")], placement: .older("before-a1"), base: window))
        #expect(edges(state).isEmpty)
        #expect(ConversationProjection.project(state).messages.map(\.text) == ["a0", "a1", "b1"])

        var farBack = ConversationState(conversationID: UUID(), threadID: "thread")
        farBack.merge(.fixture(wire: [entry("b1", turn: "b"), entry("a1", turn: "a")], turns: [turn("b"), turn("a")],
            older: "before-a1", newer: "after-b1", placement: .reset))
        #expect(edges(farBack) == ["history-edge-older", "history-edge-newer"])
        #expect(ConversationProjection.project(farBack).items.last?.id == "history-edge-newer")
    }

    @Test func discardedLiveItemsBecomeAReloadEdgeUntilTheTailCoversTheirTurn() {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: [entry("a1", turn: "a")], turns: [turn("a")]))
        let checkpoint = CodexAppServerV2.ThreadObservationCheckpoint(turnsBackwardsCursor: nil, itemsBackwardsCursor: nil,
            activeTurn: nil, historyUnavailable: true, liveItems: [entry("b2", turn: "b")])
        state.mergeObservation(header: .historyFixture(), checkpoint: checkpoint, history: .init(turns: [], entries: [], update: nil))
        #expect(edges(state) == ["history-edge-reload-b"])

        state.merge(.fixture(wire: [entry("b2", turn: "b"), entry("b1", turn: "b"), entry("a1", turn: "a")], turns: [turn("b"), turn("a")]))
        #expect(edges(state).isEmpty)
        #expect(ConversationProjection.project(state).messages.map(\.text) == ["a1", "b1", "b2"])
    }
}
