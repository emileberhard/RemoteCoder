import Foundation
@testable import RemoteCoderCore

protocol ConversationHistoryFixtures {}

extension ConversationHistoryFixtures {
    func history(items: [CodexAppServerV2.ThreadItem], turnID: String = "turn", threadID: String = "thread",
                 status: CodexAppServerV2.TurnStatus = .inProgress) -> GatewayHistoryService.ConversationSnapshot {
        .fixture(threadID: threadID, wire: entries(items, turnID: turnID), turns: [summary(turnID, status: status)])
    }

    func entries(_ items: [CodexAppServerV2.ThreadItem], turnID: String,
                 ordered: Bool = true) -> [CodexAppServerV2.ThreadItemsListResponse.Entry] {
        items.enumerated().reversed().map { index, item in
            .init(turnId: turnID, item: item, startedAtOrdinal: ordered ? Int64(index) : nil, startedAtMs: 1000, isComplete: true)
        }
    }

    func summary(_ id: String, status: CodexAppServerV2.TurnStatus = .inProgress) -> CodexAppServerV2.Turn {
        CodexAppServerV2.Turn(id: id, items: [], startedAt: 1, completedAt: status == .inProgress ? nil : 2,
                              status: status, error: nil)
    }

    func measured(_ wire: [CodexAppServerV2.ThreadItemsListResponse.Entry], older: String?, placement: HistoryWindow.Placement,
                  base: HistoryWindow?) -> GatewayHistoryService.ConversationSnapshot {
        var items = HistoryWindow.ItemPage(elements: wire.reversed(), older: older,
            newer: placement.readsTail ? nil : "after-\(wire.last?.turnId ?? "")", fetchedAt: .now)
        items.encodedBytes = HistoryWindow.byteBudget / 2 + 1
        let update = HistoryWindow.Update(items: items, placement: placement, metadata: [])
        var window = base ?? HistoryWindow()
        window.apply(update)
        return .init(header: .historyFixture(), window: window, update: update, fetchedAt: .now, source: .gateway)
    }

    func event(_ method: String, item: CodexAppServerV2.ThreadItem, ordinal: Int, threadID: String = "thread",
               completedAtMs: Int = 2000) throws -> TurnScopedGatewayEvent {
        try GatewayEventFixture.item(method, item: item, threadID: threadID, turnID: "turn", ordinal: ordinal,
            startedAtMs: 1000, completedAtMs: completedAtMs)
    }

    func agentDelta(_ text: String) throws -> TurnScopedGatewayEvent {
        try GatewayEventFixture.delta(text, threadID: "thread", turnID: "turn", itemID: "answer")
    }
}
