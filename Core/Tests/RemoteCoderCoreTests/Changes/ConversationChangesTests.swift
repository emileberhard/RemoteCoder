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
        guard case .turn(let turn) = changes.window else {
            Issue.record("Expected one turn")
            return
        }
        #expect(turn.id == "turn-1")
        #expect(turn.latest && !turn.running)
        #expect(changes.files.map(\.root) == ["/nonexistent-fixture/care/src", "/nonexistent-fixture"])
        #expect(UnifiedDiff.parse(changes.files[1].change).status == .added)
        #expect(changes.commands == 3 && changes.omittedAgents == 1 && !changes.complete)
    }

    @Test func rangeChangesKeepTheirStartAndCountedTurns() throws {
        let read = try JSONDecoder().decode(TurnChangesRead.self, from: ProtocolFixtures.data(at: "changes/range-ready.json"))
        guard case .ready(let changes) = read, case .since(let since) = changes.window else {
            Issue.record("Expected ready range changes")
            return
        }
        #expect(since.anchor == ChangesAnchor(turnID: "turn-3", boundary: .end))
        #expect(since.at == Date(timeIntervalSince1970: 1_793_636_561) && since.turns == 2)
        #expect(changes.files.map(\.root) == ["/nonexistent-fixture/care/src", "/nonexistent-fixture"])
        #expect(changes.totals == ChangeTotals(counted: [ChangeTotals.Lines(additions: 1, deletions: 1),
                                                         ChangeTotals.Lines(additions: 1, deletions: 0)],
                                               unlistedFiles: 0, isComplete: false))
        let missing = try JSONDecoder().decode(TurnChangesRead.self, from: Data(#"{"status":"anchorMissing","complete":false}"#.utf8))
        guard case .anchorMissing(let complete) = missing else {
            Issue.record("Expected a missing start point")
            return
        }
        #expect(!complete)
    }

    @Test func noRecentEditsKeepsItsCoverage() throws {
        let read = try JSONDecoder().decode(TurnChangesRead.self, from: Data(#"{"status":"noRecentEdits","complete":false}"#.utf8))
        guard case .noRecentEdits(let complete) = read else {
            Issue.record("Expected no recent edits")
            return
        }
        #expect(!complete)
    }

    @Test func summaryKeepsCountsEvidenceFailuresAndPrimaryComparison() throws {
        let summary = try JSONDecoder().decode(ChangeSummary.self, from: ProtocolFixtures.data(at: "changes/summary.json"))
        let prepared = PreparedChangeSummary(summary)
        #expect(prepared.workedIn.map(\.root) == ["/Users/agent/configs", "/Users/agent/RemoteCoder-worktrees/x",
                                                "/Users/agent/gone", "/Users/agent/broken"])
        #expect(prepared.workedIn[1].evidence == [.edited, .command])
        #expect(prepared.workedIn.map { $0.totals?.files } == [0, 1, nil, nil])
        #expect(prepared.workedIn[1].totals?.lines == ChangeTotals.Lines(additions: 3, deletions: 1))
        #expect(prepared.totals.files == 1 && prepared.totals.lines == nil)
        #expect(prepared.primary == PreparedChangeSummary.Primary(root: "/Users/agent/RemoteCoder-worktrees/x", source: .branch))
        #expect(prepared.inFolder == ["/Users/agent/stretch/kartan"] && !prepared.complete)
        guard case .unavailable(.missingDirectory) = summary.workedIn[2].outcome,
              case .failed = summary.workedIn[3].outcome else {
            Issue.record("Unavailable and failed outcomes must remain distinct")
            return
        }
    }

    @Test func primaryIsAbsentWithoutKnownChangesAndUsesUncommittedWhenReported() throws {
        for (files, source) in [(0, "branch"), (2, "uncommitted")] {
            let data = Data("""
            {"workedIn":[{"root":"/repo","evidence":["workingFolder"],"status":"ready",
            "snapshot":{"source":"\(source)","root":"/repo","files":[],"unlistedFiles":\(files),"complete":true,"capturedAtMs":0}}],
            "inFolder":[],"complete":true}
            """.utf8)
            let prepared = PreparedChangeSummary(try JSONDecoder().decode(ChangeSummary.self, from: data))
            #expect(prepared.primary == (files == 0 ? nil : .init(root: "/repo", source: .uncommitted)))
        }
    }
}
