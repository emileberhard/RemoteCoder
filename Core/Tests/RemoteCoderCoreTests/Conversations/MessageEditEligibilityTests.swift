import Foundation
import Testing
@testable import RemoteCoderCore

struct MessageEditEligibilityTests: ConversationHistoryFixtures {
    private typealias Turn = (id: String, status: CodexAppServerV2.TurnStatus, items: [CodexAppServerV2.ThreadItem])

    @Test func theFirstMessageEditsFromTheStartAndALaterOneForksAfterTheFinishedTurnBeforeIt() throws {
        let snapshot = project([("t1", .completed, exchange("first")), ("t2", .completed, exchange("second"))], older: nil)

        #expect(snapshot.editBases[try message("first", in: snapshot)] == .threadStart)
        #expect(snapshot.editBases[try message("second", in: snapshot)] == .afterTurn("t1"))
        #expect(snapshot.editBases.count == 2)
    }

    @Test func aSteerIsNotEditableButItsTurnsHeadIs() throws {
        let items: [CodexAppServerV2.ThreadItem] = [user("head"), .agentMessage(id: "a-head", text: "Working"),
                                                   user("steer"), .agentMessage(id: "a-steer", text: "Done")]
        let snapshot = project([("t1", .completed, items)], older: nil)

        #expect(snapshot.editBases[try message("head", in: snapshot)] == .threadStart)
        #expect(snapshot.editBases[try message("steer", in: snapshot)] == nil)
    }

    @Test func thePartlyLoadedOldestTurnIsNotEditableButTheTurnAfterItIs() throws {
        let snapshot = project([("t1", .completed, exchange("partial")), ("t2", .completed, exchange("later"))],
                               older: "before-t1")

        #expect(snapshot.editBases[try message("partial", in: snapshot)] == nil)
        #expect(snapshot.editBases[try message("later", in: snapshot)] == .afterTurn("t1"))
    }

    @Test func anUnknownOrUnfinishedPreviousTurnRefusesTheEdit() throws {
        let unknown = project([("t1", .completed, exchange("first")), ("t2", .completed, exchange("second"))],
                              older: nil, summaries: ["t2"])
        #expect(unknown.editBases[try message("second", in: unknown)] == nil)

        let running = project([("t1", .inProgress, exchange("first")), ("t2", .completed, exchange("second"))], older: nil)
        #expect(running.editBases[try message("second", in: running)] == nil)
    }

    @Test func aMessageWithAnImageCannotBeRestoredSoItIsNotEditable() throws {
        let withImage = CodexAppServerV2.ThreadItem.userMessage(id: "u-image",
            content: [.text(text: "image", textElements: []), .localImage(path: "/tmp/shot.png")])
        let snapshot = project([("t1", .completed, [withImage, .agentMessage(id: "a", text: "Seen")])], older: nil)

        #expect(snapshot.editBases[try message("image", in: snapshot)] == nil)
    }

    private func project(_ turns: [Turn], older: String?, summaries: Set<String>? = nil) -> ConversationSnapshot {
        var ordinal: Int64 = 0
        let wire = turns.flatMap { turn in
            turn.items.map { item in
                defer { ordinal += 1 }
                return CodexAppServerV2.ThreadItemsListResponse.Entry(turnId: turn.id, item: item, startedAtOrdinal: ordinal,
                                                                      startedAtMs: 1000, isComplete: true)
            }
        }
        let known = turns.filter { summaries?.contains($0.id) ?? true }
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(.fixture(wire: wire.reversed(), turns: known.reversed().map { summary($0.id, status: $0.status) }, older: older))
        return ConversationProjection.project(state)
    }

    private func exchange(_ text: String) -> [CodexAppServerV2.ThreadItem] {
        [user(text), .agentMessage(id: "a-\(text)", text: "Reply to \(text)")]
    }

    private func user(_ text: String) -> CodexAppServerV2.ThreadItem {
        .userMessage(id: "u-\(text)", content: [.text(text: text, textElements: [])])
    }

    private func message(_ text: String, in snapshot: ConversationSnapshot) throws -> UUID {
        try #require(snapshot.messages.first { $0.role == .user && $0.text == text }).id
    }
}
