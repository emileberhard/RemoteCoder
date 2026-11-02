import SwiftUI

struct ChangeReview: Sendable {
    let source: ChangeSource
    let root: String
    let branch: String?
    let base: String?
    let capturedAt: Date
    let files: [ReviewedFile]
    let unlistedFiles: Int
    let isComplete: Bool
    let lineCounts: LineCounts?

    struct LineCounts: Sendable {
        let additions: Int
        let deletions: Int
    }

    func contains(_ anchor: ReviewNote.Anchor) -> Bool {
        anchor.source == source && files.contains { file in
            file.path == anchor.path && file.rows.contains { file.anchor(for: $0) == anchor }
        }
    }
}

struct ReviewedFile: Identifiable, Sendable, Equatable {
    let id: String
    let revision: Int
    let source: ChangeSource
    let path: String
    let status: FileDiff.Status
    let modeChange: FileDiff.ModeChange?
    let isBinary: Bool
    let isConflict: Bool
    let hasLineCounts: Bool
    let additions: Int
    let deletions: Int
    let omission: ChangeSnapshot.Omission?
    let replacedInvalidUTF8: Bool
    let rows: [DiffRow]

    func anchor(for row: DiffRow) -> ReviewNote.Anchor? {
        guard case .line(let side) = row.kind, let line = side == .deletion ? row.oldNumber : row.newNumber else { return nil }
        return ReviewNote.Anchor(source: source, path: path, line: line, side: side, excerpt: row.plain)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.revision == rhs.revision }
}

struct DiffRow: Identifiable, Sendable, Equatable {
    enum Kind: Equatable, Sendable {
        case gap(hiddenLines: Int?, section: String)
        case line(DiffLine.Kind)
    }

    let id: Int
    let revision: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let indent: Int
    let text: AttributedString
    let plain: String
    let hiddenCharacters: Int
    let lacksFinalNewline: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.revision == rhs.revision }
}

enum ChangeReviewPreparation {
    static let displayedLineCharacters = 2_000
    private static let emphasizedLineCharacters = 1_000
    private static let maximumHangingIndent = 24
    private static let maximumRows = 10_000

    @concurrent static func prepare(_ snapshot: ChangeSnapshot, revision: Int) async -> ChangeReview {
        review(of: snapshot, revision: revision)
    }

    static func review(of snapshot: ChangeSnapshot, revision: Int) -> ChangeReview {
        var occurrences: [String: Int] = [:]
        var remainingRows = maximumRows
        var files: [ReviewedFile] = []
        for file in snapshot.files {
            guard !Task.isCancelled else { break }
            let lines = file.patch.utf8.count(where: { $0 == UInt8(ascii: "\n") })
            let fits = lines <= remainingRows
            if fits { remainingRows -= lines }
            let diff = fits ? UnifiedDiff.parse(file) : UnifiedDiff.header(of: file)
            let occurrence = occurrences[diff.path, default: 0]
            occurrences[diff.path] = occurrence + 1
            let omission = fits ? diff.omission : diff.omission ?? ChangeSnapshot.Omission(reason: .responseBudget,
                                                                                             patchBytes: file.patch.utf8.count)
            files.append(reviewedFile(diff, id: occurrence == 0 ? diff.path : "\(diff.path)#\(occurrence)", source: snapshot.source,
                                      revision: revision, omission: omission))
        }
        let knowsEveryCount = snapshot.complete && snapshot.unlistedFiles == 0 && files.allSatisfy { $0.hasLineCounts || $0.isBinary }
        return ChangeReview(
            source: snapshot.source,
            root: snapshot.root,
            branch: snapshot.branch,
            base: snapshot.base,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(snapshot.capturedAtMs) / 1_000),
            files: files,
            unlistedFiles: snapshot.unlistedFiles,
            isComplete: snapshot.complete,
            lineCounts: knowsEveryCount ? ChangeReview.LineCounts(additions: files.reduce(0) { $0 + $1.additions },
                                                                  deletions: files.reduce(0) { $0 + $1.deletions }) : nil
        )
    }

    static func language(forPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "py": "python"
        case "js", "jsx", "mjs", "cjs": "javascript"
        case "ts", "tsx", "mts", "cts": "typescript"
        case "rs": "rust"
        default: nil
        }
    }

    private static func reviewedFile(_ diff: FileDiff, id: String, source: ChangeSource, revision: Int,
                                     omission: ChangeSnapshot.Omission?) -> ReviewedFile {
        let language = language(forPath: diff.path)
        var rows: [DiffRow] = []
        var previousEnd: Int?
        for hunk in diff.hunks {
            let start = max(hunk.newStart, 1)
            let hidden = previousEnd.map { start - $0 } ?? (hunk.oldStart > 0 ? start - 1 : 0)
            if hidden > 0 || !hunk.section.isEmpty || previousEnd != nil {
                rows.append(gapRow(id: rows.count, revision: revision, hidden: hidden, section: hunk.section))
            }
            previousEnd = hunk.newStart + hunk.newCount
            let expanded = hunk.lines.map { $0.text.replacing("\t", with: "    ") }
            let dedent = expanded.lazy.filter { !$0.allSatisfy(\.isWhitespace) }
                .map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
            let shown = expanded.map { String($0.dropFirst(min(dedent, $0.prefix(while: { $0 == " " }).count))) }
            let emphasis = changedRanges(in: zip(hunk.lines, shown).map { ($0.kind, $1) })
            for (index, line) in hunk.lines.enumerated() {
                rows.append(lineRow(id: rows.count, revision: revision, line: line, shown: shown[index], language: language,
                                    emphasis: emphasis[index]))
            }
        }
        return ReviewedFile(
            id: id,
            revision: revision,
            source: source,
            path: diff.path,
            status: diff.status,
            modeChange: diff.modeChange,
            isBinary: diff.isBinary,
            isConflict: diff.isConflict,
            hasLineCounts: diff.hasLineCounts && !diff.isBinary,
            additions: diff.additions,
            deletions: diff.deletions,
            omission: omission,
            replacedInvalidUTF8: diff.replacedInvalidUTF8,
            rows: rows
        )
    }

    private static func gapRow(id: Int, revision: Int, hidden: Int, section: String) -> DiffRow {
        DiffRow(id: id, revision: revision, kind: .gap(hiddenLines: hidden > 0 ? hidden : nil, section: section), oldNumber: nil, newNumber: nil,
                indent: 0, text: AttributedString(section), plain: section, hiddenCharacters: 0, lacksFinalNewline: false)
    }

    private static func lineRow(id: Int, revision: Int, line: DiffLine, shown: String, language: String?,
                                emphasis: Range<Int>?) -> DiffRow {
        let indent = min(shown.prefix(while: { $0 == " " }).count, maximumHangingIndent)
        let content = shown.dropFirst(indent)
        let visible = content.count > displayedLineCharacters ? String(content.prefix(displayedLineCharacters)) : String(content)
        var text = language == nil ? AttributedString(visible) : SyntaxHighlighting.highlight(visible, language: language)
        if let emphasis {
            let lower = max(emphasis.lowerBound - indent, 0)
            let upper = min(emphasis.upperBound - indent, visible.count)
            if lower < upper {
                let characters = text.characters
                let start = characters.index(characters.startIndex, offsetBy: lower)
                text[start..<characters.index(start, offsetBy: upper - lower)].backgroundColor = DiffPalette.emphasis(line.kind)
            }
        }
        return DiffRow(id: id, revision: revision, kind: .line(line.kind), oldNumber: line.oldNumber, newNumber: line.newNumber,
                       indent: indent, text: text, plain: line.text, hiddenCharacters: content.count - visible.count,
                       lacksFinalNewline: line.lacksFinalNewline)
    }

    private static func changedRanges(in lines: [(kind: DiffLine.Kind, text: String)]) -> [Range<Int>?] {
        var ranges = [Range<Int>?](repeating: nil, count: lines.count)
        var index = 0
        while index < lines.count {
            let deletions = index..<(lines[index...].firstIndex { $0.kind != .deletion } ?? lines.count)
            let additions = deletions.upperBound..<(lines[deletions.upperBound...].firstIndex { $0.kind != .addition } ?? lines.count)
            guard !deletions.isEmpty, !additions.isEmpty else {
                index = max(index + 1, additions.upperBound)
                continue
            }
            for offset in 0..<min(deletions.count, additions.count) {
                let old = deletions.lowerBound + offset
                let new = additions.lowerBound + offset
                if let (removed, added) = changedSpan(lines[old].text, lines[new].text) {
                    ranges[old] = removed
                    ranges[new] = added
                }
            }
            index = additions.upperBound
        }
        return ranges
    }

    private static func changedSpan(_ old: String, _ new: String) -> (Range<Int>, Range<Int>)? {
        guard old.count <= emphasizedLineCharacters, new.count <= emphasizedLineCharacters else { return nil }
        let old = Array(old)
        let new = Array(new)
        let shorter = min(old.count, new.count)
        var prefix = 0
        while prefix < shorter, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let shared = prefix + suffix
        guard shared > 0, shared * 3 >= max(old.count, new.count), shared < max(old.count, new.count) else { return nil }
        return (prefix..<(old.count - suffix), prefix..<(new.count - suffix))
    }
}

enum DiffPalette {
    static func line(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.12)
        case .deletion: .red.opacity(0.12)
        case .context: .clear
        }
    }

    static func gutter(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.24)
        case .deletion: .red.opacity(0.24)
        case .context: .clear
        }
    }

    static func emphasis(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.32)
        case .deletion: .red.opacity(0.32)
        case .context: .clear
        }
    }

    static let added = Color.green
    static let removed = Color.red
}
