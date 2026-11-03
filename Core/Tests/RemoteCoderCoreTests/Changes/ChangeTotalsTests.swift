import Testing
@testable import RemoteCoderCore

struct ChangeTotalsTests {
    private let modified = ChangeSnapshot.File(
        patch: "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1,2 @@\n-x\n+y\n+z\n",
        additions: 2, deletions: 1, omitted: nil, replacedInvalidUtf8: false)
    private let binary = ChangeSnapshot.File(
        patch: "diff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n",
        additions: 0, deletions: 0, omitted: nil, replacedInvalidUtf8: false)
    private let unmerged = ChangeSnapshot.File(
        patch: "* Unmerged path c.swift\n", additions: 0, deletions: 0, omitted: nil, replacedInvalidUtf8: false)

    private func snapshot(_ files: [ChangeSnapshot.File], unlistedFiles: Int = 0, complete: Bool = true) -> ChangeSnapshot {
        ChangeSnapshot(source: .uncommitted, root: "/repo", branch: "main", base: nil, capturedAtMs: 0,
                       files: files, unlistedFiles: unlistedFiles, complete: complete)
    }

    @Test func binaryFilesKeepTheLineTotalsKnown() {
        let totals = ChangeTotals(snapshot([modified, binary]))
        #expect(totals.files == 2)
        #expect(totals.lines == ChangeTotals.Lines(additions: 2, deletions: 1))
    }

    @Test func anyUncountedFileLeavesTheLineTotalsUnknown() {
        #expect(ChangeTotals(snapshot([modified, unmerged])).lines == nil)
        #expect(ChangeTotals(snapshot([modified], complete: false)).lines == nil)

        let unlisted = ChangeTotals(snapshot([modified], unlistedFiles: 3))
        #expect(unlisted.files == 4)
        #expect(unlisted.lines == nil)
    }

    @Test func summingAddsKnownFilesAndRequiresEveryLineCount() {
        let known = ChangeTotals(snapshot([modified, binary]))
        let other = ChangeTotals(snapshot([modified]))
        let summed = ChangeTotals(summing: [known, other])
        #expect(summed.files == 3)
        #expect(summed.lines == ChangeTotals.Lines(additions: 4, deletions: 2))
        for unknown in [nil, ChangeTotals(snapshot([unmerged])), ChangeTotals(snapshot([modified], complete: false))] {
            let sum = ChangeTotals(summing: [known, unknown])
            #expect(sum.files == 2 + (unknown?.files ?? 0))
            #expect(sum.lines == nil)
        }
        let empty = ChangeTotals(summing: [ChangeTotals?]())
        #expect(empty.files == 0 && empty.lines == .init(additions: 0, deletions: 0))
    }
}
