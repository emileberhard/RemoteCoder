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
