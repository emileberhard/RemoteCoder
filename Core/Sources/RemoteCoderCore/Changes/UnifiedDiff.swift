import Foundation

struct FileDiff: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case added, deleted, modified
        case renamed(from: String)
        case copied(from: String)
    }

    struct ModeChange: Equatable, Sendable {
        let old: String
        let new: String
    }

    let path: String
    let status: Status
    let modeChange: ModeChange?
    let isBinary: Bool
    let isConflict: Bool
    let hasLineCounts: Bool
    let additions: Int
    let deletions: Int
    let hunks: [DiffHunk]
    let omission: ChangeSnapshot.Omission?
    let replacedInvalidUTF8: Bool
}

struct DiffHunk: Equatable, Sendable {
    let oldStart: Int
    let newStart: Int
    let oldCount: Int
    let newCount: Int
    let section: String
    let lines: [DiffLine]
}

struct DiffLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case context, addition, deletion
    }

    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    var lacksFinalNewline = false
}

enum UnifiedDiff {
    static func header(of file: ChangeSnapshot.File) -> FileDiff {
        guard let firstHunk = file.patch.range(of: "\n@@") else { return parse(file) }
        return parse(ChangeSnapshot.File(patch: String(file.patch[..<firstHunk.upperBound].dropLast(2)), additions: file.additions,
                                         deletions: file.deletions, omitted: file.omitted,
                                         replacedInvalidUtf8: file.replacedInvalidUtf8))
    }

    static func parse(_ file: ChangeSnapshot.File) -> FileDiff {
        var lines = file.patch.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(Substring.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var header = Header()
        var hunks: [DiffHunk] = []
        var hunk: HunkBuilder?
        for line in lines {
            if let next = HunkBuilder(header: line) {
                if let hunk { hunks.append(hunk.build()) }
                hunk = next
            } else if hunk != nil {
                hunk?.append(line)
            } else {
                header.read(line)
            }
        }
        if let hunk { hunks.append(hunk.build()) }
        return FileDiff(
            path: header.path,
            status: header.status,
            modeChange: header.modeChange,
            isBinary: header.isBinary,
            isConflict: header.isConflict,
            hasLineCounts: !header.isUnmergedNotice,
            additions: file.additions,
            deletions: file.deletions,
            hunks: hunks,
            omission: file.omitted,
            replacedInvalidUTF8: file.replacedInvalidUtf8
        )
    }

    static func unquote(_ path: Substring) -> String {
        guard path.count >= 2, path.first == "\"", path.last == "\"" else { return String(path) }
        var bytes: [UInt8] = []
        var iterator = path.dropFirst().dropLast().utf8.makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\"), let escaped = iterator.next() else {
                bytes.append(byte)
                continue
            }
            switch escaped {
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "3"):
                var value = escaped - UInt8(ascii: "0")
                for _ in 0..<2 {
                    guard let digit = iterator.next(), (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    value = value * 8 + (digit - UInt8(ascii: "0"))
                }
                bytes.append(value)
            default: bytes.append(escaped)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct Header {
    var gitPath: String?
    var oldPath: String?
    var newPath: String?
    var renamedFrom: String?
    var renamedTo: String?
    var copiedFrom: String?
    var copiedTo: String?
    var isNew = false
    var isDeleted = false
    var oldMode: String?
    var newMode: String?
    var isBinary = false
    var isConflict = false
    var isUnmergedNotice = false

    var path: String {
        renamedTo ?? copiedTo ?? newPath ?? oldPath ?? gitPath ?? ""
    }

    var status: FileDiff.Status {
        if let renamedFrom { return .renamed(from: renamedFrom) }
        if let copiedFrom { return .copied(from: copiedFrom) }
        if isNew { return .added }
        if isDeleted { return .deleted }
        return .modified
    }

    var modeChange: FileDiff.ModeChange? {
        guard let oldMode, let newMode, oldMode != newMode else { return nil }
        return FileDiff.ModeChange(old: oldMode, new: newMode)
    }

    mutating func read(_ line: Substring) {
        if let rest = line.dropping("diff --git ") {
            gitPath = Self.sharedGitPath(rest)
        } else if let rest = line.dropping("diff --cc ") ?? line.dropping("diff --combined ") {
            isConflict = true
            gitPath = UnifiedDiff.unquote(rest)
        } else if let rest = line.dropping("* Unmerged path ") {
            isConflict = true
            isUnmergedNotice = true
            gitPath = String(rest)
        } else if let rest = line.dropping("--- ") {
            oldPath = Self.patchPath(rest, prefix: "a/")
        } else if let rest = line.dropping("+++ ") {
            newPath = Self.patchPath(rest, prefix: "b/")
        } else if let rest = line.dropping("rename from ") {
            renamedFrom = UnifiedDiff.unquote(rest)
        } else if let rest = line.dropping("rename to ") {
            renamedTo = UnifiedDiff.unquote(rest)
        } else if let rest = line.dropping("copy from ") {
            copiedFrom = UnifiedDiff.unquote(rest)
        } else if let rest = line.dropping("copy to ") {
            copiedTo = UnifiedDiff.unquote(rest)
        } else if let rest = line.dropping("new file mode ") {
            isNew = true
            newMode = String(rest)
        } else if let rest = line.dropping("deleted file mode ") {
            isDeleted = true
            oldMode = String(rest)
        } else if let rest = line.dropping("old mode ") {
            oldMode = String(rest)
        } else if let rest = line.dropping("new mode ") {
            newMode = String(rest)
        } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
            isBinary = true
        }
    }

    private static func patchPath(_ raw: Substring, prefix: String) -> String? {
        var raw = raw
        if raw.last == "\t" { raw = raw.dropLast() }
        guard raw != "/dev/null" else { return nil }
        let path = UnifiedDiff.unquote(raw)
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func sharedGitPath(_ rest: Substring) -> String? {
        if rest.first == "\"" { return quotedOldPath(rest) }
        let length = rest.utf8.count
        guard length >= 5, (length - 5).isMultiple(of: 2), rest.hasPrefix("a/") else { return nil }
        let half = (length - 5) / 2
        let utf8 = rest.utf8
        let oldStart = utf8.index(utf8.startIndex, offsetBy: 2)
        let oldEnd = utf8.index(oldStart, offsetBy: half)
        let separatorEnd = utf8.index(oldEnd, offsetBy: 3)
        guard utf8[oldEnd..<separatorEnd].elementsEqual(" b/".utf8),
              utf8[oldStart..<oldEnd].elementsEqual(utf8[separatorEnd...]),
              let path = String(utf8[oldStart..<oldEnd]) else { return nil }
        return path
    }

    private static func quotedOldPath(_ rest: Substring) -> String? {
        var escaped = false
        for index in rest.indices.dropFirst() {
            let character = rest[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let path = UnifiedDiff.unquote(rest[...index])
                return path.hasPrefix("a/") ? String(path.dropFirst(2)) : path
            }
        }
        return nil
    }
}

private struct HunkBuilder {
    let parents: Int
    let oldStart: Int
    let newStart: Int
    let oldCount: Int
    let newCount: Int
    let section: String
    var oldNumber: Int
    var newNumber: Int
    var lines: [DiffLine] = []

    init?(header line: Substring) {
        let markers = line.prefix(while: { $0 == "@" }).count
        guard markers >= 2, line.dropFirst(markers).first == " " else { return nil }
        let closing = " " + String(repeating: "@", count: markers)
        guard let close = line.dropFirst(markers + 1).range(of: closing) else { return nil }
        let ranges = line[line.index(line.startIndex, offsetBy: markers + 1)..<close.lowerBound].split(separator: " ")
        guard ranges.count == markers, let new = Self.range(ranges[markers - 1], sign: "+"),
              let old = Self.range(ranges[0], sign: "-") else { return nil }
        parents = markers - 1
        (oldStart, oldCount) = old
        (newStart, newCount) = new
        var section = line[close.upperBound...].drop(while: { $0 == " " })
        if section.last == "\r" { section = section.dropLast() }
        self.section = String(section)
        oldNumber = oldStart
        newNumber = newStart
    }

    mutating func append(_ line: Substring) {
        if line.first == "\\" {
            if !lines.isEmpty { lines[lines.count - 1].lacksFinalNewline = true }
            return
        }
        let columns = line.prefix(parents)
        guard columns.count == parents, columns.allSatisfy({ $0 == " " || $0 == "+" || $0 == "-" }) else { return }
        var text = line.dropFirst(parents)
        if text.last == "\r" { text = text.dropLast() }
        let first = columns.first
        if columns.contains("-") {
            let inFirstParent = first == "-"
            lines.append(DiffLine(kind: .deletion, text: String(text), oldNumber: inFirstParent ? oldNumber : nil, newNumber: nil))
            if inFirstParent { oldNumber += 1 }
        } else if columns.contains("+") {
            let inFirstParent = first == " "
            lines.append(DiffLine(kind: .addition, text: String(text), oldNumber: inFirstParent ? oldNumber : nil, newNumber: newNumber))
            if inFirstParent { oldNumber += 1 }
            newNumber += 1
        } else {
            lines.append(DiffLine(kind: .context, text: String(text), oldNumber: oldNumber, newNumber: newNumber))
            oldNumber += 1
            newNumber += 1
        }
    }

    func build() -> DiffHunk {
        DiffHunk(oldStart: oldStart, newStart: newStart, oldCount: oldCount, newCount: newCount, section: section, lines: lines)
    }

    private static func range(_ token: Substring, sign: Character) -> (start: Int, count: Int)? {
        guard token.first == sign else { return nil }
        let parts = token.dropFirst().split(separator: ",", maxSplits: 1)
        guard let first = parts.first, let start = Int(first) else { return nil }
        guard parts.count == 2 else { return (start, 1) }
        guard let count = Int(parts[1]) else { return nil }
        return (start, count)
    }
}

private extension Substring {
    func dropping(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
