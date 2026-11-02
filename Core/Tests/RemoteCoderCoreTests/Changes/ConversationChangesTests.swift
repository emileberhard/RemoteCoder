import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationChangesTests {
    @Test func turnChangesKeepEachFilesRoot() throws {
        let read = try JSONDecoder().decode(TurnChangesRead.self, from: ProtocolFixtures.data(at: "changes/turn-ready.json"))
        guard case .ready(let changes) = read else {
            Issue.record("Expected ready turn changes")
            return
        }
        #expect(changes.turn.id == "turn-1")
        #expect(changes.turn.latest && !changes.turn.running)
        #expect(changes.files.map(\.root) == ["/nonexistent-fixture/care/src", "/nonexistent-fixture"])
        #expect(UnifiedDiff.parse(changes.files[1].change).status == .added)
        #expect(changes.commands == 3 && changes.omittedAgents == 1 && !changes.complete)
    }

    @Test func noRecentEditsKeepsItsCoverage() throws {
        let read = try JSONDecoder().decode(TurnChangesRead.self, from: Data(#"{"status":"noRecentEdits","complete":false}"#.utf8))
        guard case .noRecentEdits(let complete) = read else {
            Issue.record("Expected no recent edits")
            return
        }
        #expect(!complete)
    }

    @Test func checkoutsKeepTheirEvidence() throws {
        let discovery = try JSONDecoder().decode(CheckoutDiscovery.self, from: ProtocolFixtures.data(at: "changes/checkouts.json"))
        #expect(discovery.workedIn.map(\.root) == ["/Users/agent/stretch/care.ai.worktrees/codeact", "/Users/agent/stretch/care.ai"])
        #expect(discovery.workedIn[0].evidence == [.edited, .command])
        #expect(discovery.inFolder == ["/Users/agent/stretch/kartan"])
        #expect(discovery.complete)
    }
}
