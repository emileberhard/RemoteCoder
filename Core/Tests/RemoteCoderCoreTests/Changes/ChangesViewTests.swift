import Foundation
import Testing
@testable import RemoteCoderCore

struct ChangesViewTests {
    private let end = ChangesAnchor(turnID: "turn-3", boundary: .end)

    @Test func viewsRoundTripTheirGatewayForm() throws {
        let views: [ChangesView] = [.lastTurn, .git(.staged), .since(end)]
        let encoded = try views.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as? NSDictionary }
        #expect(encoded == [["kind": "lastTurn"], ["kind": "git", "source": "staged"],
                            ["kind": "since", "turnId": "turn-3", "boundary": "end"]])
        let decoded = try views.map { try JSONDecoder().decode(ChangesView.self, from: JSONEncoder().encode($0)) }
        #expect(decoded == views)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChangesView.self, from: Data(#"{"kind":"commit"}"#.utf8))
        }
    }

    @Test func onlyTheStandardViewHidesItsLabelAndItsZeroCount() {
        let none = ChangeTotals(counted: [ChangeTotals.Lines?](), unlistedFiles: 0, isComplete: true)
        let branch = ChangesPillContent(view: .standard, totals: none)
        #expect(branch.label == nil && !branch.isVisible)
        let lastTurn = ChangesPillContent(view: .lastTurn, totals: none)
        #expect(lastTurn.label == "Last Turn" && lastTurn.isVisible)
        #expect(ChangesPillContent(view: .git(.unstaged), totals: none).label == "Unstaged")
        let missing = ChangesPillContent(view: .since(end), totals: nil)
        #expect(missing.label == "Since" && missing.isVisible)
    }

    @Test func aSinceLabelNamesItsStartOrNowWhileTheStartTurnRuns() {
        let now = Date(timeIntervalSince1970: 1_793_640_000)
        let started = TurnChanges.Since(anchor: end, atMs: 1_793_636_561_000, turns: 2)
        let label = ChangesView.since(end).label(since: started, now: now)
        #expect(label == "Since \(ChangesView.formattedTime(Date(timeIntervalSince1970: 1_793_636_561), now: now))")
        let running = TurnChanges.Since(anchor: end, atMs: nil, turns: 0)
        #expect(ChangesView.since(end).label(since: running, now: now) == "Since Now")
        let prompt = ChangesAnchor(turnID: "turn-3", boundary: .start)
        #expect(ChangesView.since(prompt).label(since: nil, now: now) == "Since")
    }

    @Test func startPointsListRecentPromptsAndCountNowFromTheNewestTurn() {
        let messages = [
            ChatMessage(role: .user, text: "First\nwith detail", date: Date(timeIntervalSince1970: 10), canonicalTurnID: "t1"),
            ChatMessage(role: .codex, text: "Done", canonicalTurnID: "t1"),
            ChatMessage(role: .user, text: "Second", date: Date(timeIntervalSince1970: 20), canonicalTurnID: "t2"),
            ChatMessage(role: .user, text: "Steer", wasSteered: true, canonicalTurnID: "t2"),
            ChatMessage(role: .user, text: "Pending"),
        ]
        let points = ChangesStartPoints(messages: messages, activeTurnID: nil)
        #expect(points.now == ChangesAnchor(turnID: "t2", boundary: .end))
        #expect(points.prompts.map(\.anchor.turnID) == ["t2", "t1"])
        #expect(points.prompts.map(\.preview) == ["Second", "First"])
        #expect(points.prompts.allSatisfy { $0.anchor.boundary == .start })
        #expect(ChangesStartPoints(messages: messages, activeTurnID: "t3").now?.turnID == "t3")
        #expect(ChangesStartPoints(messages: [], activeTurnID: nil) == .none)
        let many = (0..<10).map { ChatMessage(role: .user, text: "\($0)", canonicalTurnID: "t\($0)") }
        #expect(ChangesStartPoints(messages: many, activeTurnID: nil).prompts.count == ChangesStartPoints.limit)
    }
}
