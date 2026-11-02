import Foundation

struct ChangeTotals: Equatable, Sendable {
    struct Lines: Equatable, Sendable {
        let additions: Int
        let deletions: Int
    }

    let files: Int
    let lines: Lines?

    init(counted: some Sequence<Lines?>, unlistedFiles: Int, isComplete: Bool) {
        var listed = 0
        var additions = 0
        var deletions = 0
        var knowsEveryCount = isComplete && unlistedFiles == 0
        for lines in counted {
            listed += 1
            if let lines {
                additions += lines.additions
                deletions += lines.deletions
            } else {
                knowsEveryCount = false
            }
        }
        files = listed + unlistedFiles
        lines = knowsEveryCount ? Lines(additions: additions, deletions: deletions) : nil
    }

    init(_ snapshot: ChangeSnapshot) {
        self.init(counted: snapshot.files.lazy.map { UnifiedDiff.header(of: $0).countedLines },
                  unlistedFiles: snapshot.unlistedFiles, isComplete: snapshot.complete)
    }
}

extension FileDiff {
    var countedLines: ChangeTotals.Lines? {
        hasLineCounts || isBinary ? ChangeTotals.Lines(additions: additions, deletions: deletions) : nil
    }
}
