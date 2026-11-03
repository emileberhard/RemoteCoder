import Foundation
import Testing
@testable import RemoteCoderCore

struct UnifiedDiffTests {
    private func file(_ patch: String, additions: Int = 0, deletions: Int = 0) -> ChangeSnapshot.File {
        ChangeSnapshot.File(patch: patch, additions: additions, deletions: deletions, omitted: nil, replacedInvalidUtf8: false)
    }

    @Test func aModifiedFileNumbersEachSideAndKeepsTheHunkSection() throws {
        let diff = UnifiedDiff.parse(file("""
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 4cb29ea..6addb9b 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,3 +10,4 @@ struct App {
             let a = 1
        -    let b = 2
        +    let b = 3
        +    let c = 4
             let d = 5
        \\ No newline at end of file

        """, additions: 2, deletions: 1))

        #expect(diff.path == "Sources/App.swift")
        #expect(diff.status == .modified)
        #expect((diff.additions, diff.deletions) == (2, 1))
        let hunk = try #require(diff.hunks.first)
        #expect(hunk.section == "struct App {")
        #expect((hunk.oldStart, hunk.newStart, hunk.oldCount, hunk.newCount) == (10, 10, 3, 4))
        #expect(hunk.lines == [
            DiffLine(kind: .context, text: "    let a = 1", oldNumber: 10, newNumber: 10),
            DiffLine(kind: .deletion, text: "    let b = 2", oldNumber: 11, newNumber: nil),
            DiffLine(kind: .addition, text: "    let b = 3", oldNumber: nil, newNumber: 11),
            DiffLine(kind: .addition, text: "    let c = 4", oldNumber: nil, newNumber: 12),
            DiffLine(kind: .context, text: "    let d = 5", oldNumber: 12, newNumber: 13, lacksFinalNewline: true),
        ])
    }

    @Test func contentThatLooksLikeHeadersStaysContent() {
        let diff = UnifiedDiff.parse(file("""
        diff --git a/notes.md b/notes.md
        --- a/notes.md
        +++ b/notes.md
        @@ -1 +1,2 @@
        --- a/old
        +++ b/new
        +@@ -1 +1 @@

        """))

        #expect(diff.path == "notes.md")
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].lines.map(\.kind) == [.deletion, .addition, .addition])
        #expect(diff.hunks[0].lines.map(\.text) == ["-- a/old", "++ b/new", "@@ -1 +1 @@"])
    }

    @Test func newDeletedRenamedAndModeChangedFilesNameTheirChange() {
        let added = UnifiedDiff.parse(file("""
        diff --git a/new file.txt b/new file.txt
        new file mode 100644
        index 0000000..ce01362
        --- /dev/null
        +++ b/new file.txt\t
        @@ -0,0 +1 @@
        +hello

        """))
        #expect(added.path == "new file.txt")
        #expect(added.status == .added)
        #expect(added.hunks[0].lines == [DiffLine(kind: .addition, text: "hello", oldNumber: nil, newNumber: 1)])

        let deleted = UnifiedDiff.parse(file("""
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index ce01362..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -hello

        """))
        #expect(deleted.path == "gone.txt")
        #expect(deleted.status == .deleted)

        let renamed = UnifiedDiff.parse(file("""
        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt

        """))
        #expect(renamed.path == "new name.txt")
        #expect(renamed.status == .renamed(from: "old name.txt"))
        #expect(renamed.hunks.isEmpty)

        let executable = UnifiedDiff.parse(file("""
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755

        """))
        #expect(executable.path == "run.sh")
        #expect(executable.modeChange == FileDiff.ModeChange(old: "100644", new: "100755"))
    }

    @Test func quotedAndBinaryPathsAreDecoded() {
        let binary = UnifiedDiff.parse(file("""
        diff --git "a/tab\\there.png" "b/tab\\there.png"
        index 88768ef..f68ed80 100644
        Binary files "a/tab\\there.png" and "b/tab\\there.png" differ

        """))
        #expect(binary.path == "tab\there.png")
        #expect(binary.isBinary)
        #expect(UnifiedDiff.unquote("\"caf\\303\\251\"") == "café")
        #expect(UnifiedDiff.unquote("plain") == "plain")
    }

    @Test func combinedConflictDiffsUseTheResultAndFirstParentNumbers() {
        let diff = UnifiedDiff.parse(file("""
        diff --cc conflict.txt
        index 3b18e51,1f2a4b2..0000000
        --- a/conflict.txt
        +++ b/conflict.txt
        @@@ -1,1 -1,1 +1,5 @@@
        ++<<<<<<< HEAD
         +ours
        ++=======
        + theirs
        ++>>>>>>> branch
        - base

        """))

        #expect(diff.isConflict)
        #expect(diff.path == "conflict.txt")
        let lines = diff.hunks[0].lines
        #expect(lines.map(\.kind) == [.addition, .addition, .addition, .addition, .addition, .deletion])
        #expect(lines.map(\.newNumber) == [1, 2, 3, 4, 5, nil])
        #expect(lines[1] == DiffLine(kind: .addition, text: "ours", oldNumber: 1, newNumber: 2))
        #expect(lines[5] == DiffLine(kind: .deletion, text: "base", oldNumber: 2, newNumber: nil))
    }

    @Test func anOmittedFileKeepsItsHeaderCountsAndOmission() throws {
        let data = Data("""
        {"status":"ready","snapshot":{"source":"branch","root":"/r","branch":"feature",
        "base":"origin/main","capturedAtMs":1,"unlistedFiles":3,"complete":false,
        "files":[{"patch":"diff --git a/big.json b/big.json\\nindex 1..2 100644\\n--- a/big.json\\n+++ b/big.json\\n",
        "additions":4000,"deletions":12,"omitted":{"reason":"fileTooLarge","patchBytes":900000},"replacedInvalidUtf8":false}]}}
        """.utf8)

        guard case .ready(let snapshot) = try JSONDecoder().decode(ChangeRead.self, from: data) else {
            Issue.record("expected a ready snapshot")
            return
        }
        #expect(snapshot.source == .branch)
        #expect(snapshot.base == "origin/main")
        #expect(snapshot.unlistedFiles == 3)
        let diff = UnifiedDiff.parse(try #require(snapshot.files.first))
        #expect(diff.path == "big.json")
        #expect((diff.additions, diff.deletions) == (4000, 12))
        #expect(diff.hunks.isEmpty)
        #expect(diff.omission == ChangeSnapshot.Omission(reason: .fileTooLarge, patchBytes: 900_000))

        let unavailable = try JSONDecoder().decode(ChangeRead.self, from: Data(#"{"status":"unavailable","reason":"notRepository"}"#.utf8))
        guard case .unavailable(.notRepository) = unavailable else {
            Issue.record("expected notRepository")
            return
        }
    }

    @Test func reviewNotesBecomeOnePromptGroupedByComparisonAndRoot() {
        func anchor(_ comparison: ReviewComparison, root: String = "/r", _ path: String, _ line: Int, _ side: DiffLine.Kind,
                    _ excerpt: String) -> ReviewNote.Anchor {
            .init(comparison: comparison, root: root, path: path, line: line, side: side, excerpt: excerpt)
        }
        let notes = [
            ReviewNote(anchor: anchor(.git(.uncommitted), "a.swift", 12, .addition, "let x = 1"), text: " Use a constant. "),
            ReviewNote(anchor: anchor(.git(.uncommitted), "b.swift", 3, .deletion, "old()"), text: "Keep this call."),
            ReviewNote(anchor: anchor(.git(.uncommitted), "c.swift", 1, .context, "x"), text: "  "),
            ReviewNote(anchor: anchor(.git(.staged), "d.js", 1, .addition, String(repeating: "x", count: 300)), text: "Minified."),
            ReviewNote(anchor: anchor(.turn(id: "t1", startedAt: .distantPast), "e.md", 2, .addition, "Hello"), text: "Typo."),
            ReviewNote(anchor: anchor(.turn(id: "t1", startedAt: .distantPast), root: "/notes", "f.md", 1, .deletion, "Old"),
                       text: "Keep it."),
        ]
        let scope: (ReviewNote.Anchor) -> String = { anchor in
            switch anchor.comparison {
            case .git(let source): "the \(source.rawValue) changes in \(anchor.root)"
            case .turn(let id, _): "turn \(id) in \(anchor.root)"
            case .since(let start, _): "changes since turn \(start.turnID) in \(anchor.root)"
            }
        }

        #expect(ReviewNote.prompt(notes, scope: scope) == """
        Review comments on the uncommitted changes in /r:

        a.swift:12
        > + let x = 1
        Use a constant.

        b.swift:3 (removed line)
        > - old()
        Keep this call.

        Review comments on the staged changes in /r:

        d.js:1
        > + \(String(repeating: "x", count: 200))…
        Minified.

        Review comments on turn t1 in /r:

        e.md:2
        > + Hello
        Typo.

        Review comments on turn t1 in /notes:

        f.md:1 (removed line)
        > - Old
        Keep it.
        """)
        #expect(ReviewNote.prompt([notes[2]], scope: scope) == nil)
    }

    @Test func crlfLinesSplitAndKeepTheirKinds() {
        let diff = UnifiedDiff.parse(ChangeSnapshot.File(patch: "diff --git a/w.cs b/w.cs\n--- a/w.cs\n+++ b/w.cs\n@@ -1,2 +1,2 @@ class W\r\n a\r\n-b\r\n+c\r\n",
                                                         additions: 1, deletions: 1, omitted: nil, replacedInvalidUtf8: false))

        #expect(diff.hunks.first?.section == "class W")
        #expect(diff.hunks.first?.lines == [
            DiffLine(kind: .context, text: "a", oldNumber: 1, newNumber: 1),
            DiffLine(kind: .deletion, text: "b", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .addition, text: "c", oldNumber: nil, newNumber: 2),
        ])
    }

    @Test func anUnmergedPathIsAConflictWithoutHunks() {
        let diff = UnifiedDiff.parse(ChangeSnapshot.File(patch: "* Unmerged path sp \"q\" ace.txt\n", additions: 0, deletions: 0,
                                                         omitted: nil, replacedInvalidUtf8: false))

        #expect(diff.path == "sp \"q\" ace.txt")
        #expect(diff.isConflict)
        #expect(!diff.hasLineCounts)
        #expect(diff.hunks.isEmpty)
    }

    @Test func aHeaderReadStopsBeforeTheHunks() {
        let file = ChangeSnapshot.File(patch: "diff --git a/r.txt b/r.txt\nnew file mode 100644\n--- /dev/null\n+++ b/r.txt\n@@ -0,0 +1 @@\n+x\n",
                                       additions: 1, deletions: 0, omitted: nil, replacedInvalidUtf8: false)

        let header = UnifiedDiff.header(of: file)

        #expect(header.path == "r.txt")
        #expect(header.status == .added)
        #expect(header.hunks.isEmpty)
        #expect(header.additions == 1)
    }
}
