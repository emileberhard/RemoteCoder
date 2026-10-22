import Foundation

/// Markdown structure and syntax highlighting as pure data, computed once per
/// message off the main actor. Views render these blocks without parsing,
/// scanning, or regex work of their own.
enum TableAlignment: Sendable, Equatable {
    case leading, center, trailing
}

struct RenderedListItem: Sendable, Equatable {
    let content: AttributedString
    let level: Int
}

struct RenderedMarkdownBlock: Sendable, Equatable {
    enum Content: Sendable, Equatable {
        case heading(level: Int, content: AttributedString)
        case images([MarkdownImage])
        case htmlVisual(url: URL, title: String)
        case bulletList(items: [RenderedListItem])
        case codeBlock(language: String?, code: String, presentation: RenderedCodePresentation)
        case mermaid(source: String, isComplete: Bool)
        case table(headers: [AttributedString], alignments: [TableAlignment], rows: [[AttributedString]],
                   columnCharacterCounts: [Int])
        case paragraph(content: AttributedString)
        case quote(content: AttributedString)
    }

    let content: Content
    private let version = UUID()

    init(_ content: Content) {
        self.content = content
    }

    var codePresentation: RenderedCodePresentation? {
        guard case .codeBlock(_, _, let presentation) = content else { return nil }
        return presentation
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version }
}

private struct MarkdownListLine: Sendable, Equatable {
    let text: String
    let level: Int
}

private enum MarkdownBlock: Sendable, Equatable {
    case htmlVisual(url: URL, title: String)
    case heading(level: Int, text: String)
    case bulletList(items: [MarkdownListLine])
    case codeBlock(language: String?, code: String, isClosed: Bool, lineCount: Int)
    case table(headers: [String], alignments: [TableAlignment], rows: [[String]])
    case paragraph(text: String)
    case quote(text: String)
}

private struct MarkdownSegment: Sendable {
    let block: MarkdownBlock
    let offset: Int
    var openFence: OpenMarkdownFence?
}

private struct OpenMarkdownFence: Sendable {
    let fence: MarkdownFence
    let lastLineOffset: Int
    let lastCodeLineBytes: Int
}

struct MarkdownDocument: Sendable {
    static let empty = MarkdownDocument(blocks: [], containsHTMLVisual: false, source: "", segments: [], hasOptimisticTail: false)

    let blocks: [RenderedMarkdownBlock]
    let containsHTMLVisual: Bool
    fileprivate let source: String
    fileprivate let segments: [MarkdownSegment]
    fileprivate let hasOptimisticTail: Bool
}

enum MarkdownRendering {
    static func parse(_ content: String, previous: MarkdownDocument?, isStreaming: Bool,
                      highlighting: inout SyntaxHighlightCache) -> MarkdownDocument {
        let span = PerfBuild.span("markdown.parse")
        defer { span.end() }
        let segments = resumedSegments(of: content, previous: previous)
        let previousTail = previous.flatMap { $0.hasOptimisticTail ? $0.segments.count - 1 : nil }
        var containsHTMLVisual = false
        let blocks = segments.enumerated().map { index, segment -> RenderedMarkdownBlock in
            if case .htmlVisual = segment.block { containsHTMLVisual = true }
            let optimistic = isStreaming && index == segments.count - 1
            if let previous, index < previous.blocks.count, !optimistic, index != previousTail,
               previous.segments[index].block == segment.block {
                return previous.blocks[index]
            }
            let reusable: (block: MarkdownBlock, content: RenderedMarkdownBlock.Content)?
            if let previous, index < previous.blocks.count, optimistic == (index == previousTail) {
                reusable = (previous.segments[index].block, previous.blocks[index].content)
            } else {
                reusable = nil
            }
            let rendered = RenderedMarkdownBlock(render(segment.block, optimistic: optimistic, isStreaming: isStreaming,
                previous: reusable, highlighting: &highlighting))
            if let previous, index < previous.blocks.count,
               previous.blocks[index].codePresentation?.isStreaming == true,
               let presentation = rendered.codePresentation, !presentation.isStreaming,
               presentation.isCollapsible {
                PerfBuild.count("code.settleFold")
            }
            return rendered
        }
        return MarkdownDocument(blocks: blocks, containsHTMLVisual: containsHTMLVisual, source: content, segments: segments,
                                hasOptimisticTail: isStreaming && !segments.isEmpty)
    }

    private static func resumedSegments(of content: String, previous: MarkdownDocument?) -> [MarkdownSegment] {
        if let previous, let segments = extendingOpenFence(content, previous: previous) { return segments }
        guard let previous, previous.segments.count >= 2 else { return split(content, from: content.startIndex) }
        let resume = previous.segments[previous.segments.count - 2].offset
        let unchanged = previous.segments[previous.segments.count - 1].offset
        guard content.utf8.starts(with: previous.source.utf8.prefix(unchanged)) else {
            return split(content, from: content.startIndex)
        }
        return Array(previous.segments.dropLast(2))
            + split(content, from: content.utf8.index(content.startIndex, offsetBy: resume))
    }

    private static func extendingOpenFence(_ content: String, previous: MarkdownDocument) -> [MarkdownSegment]? {
        guard let segment = previous.segments.last, let open = segment.openFence,
              case .codeBlock(let language, let previousCode, false, let previousLineCount) = segment.block,
              previous.source.last?.isNewline == false,
              content.utf8.starts(with: previous.source.utf8) else { return nil }
        let start = content.utf8.index(content.startIndex, offsetBy: open.lastLineOffset)
        let lines = content[start...].split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard !lines.contains(where: open.fence.closes) else {
            let fenceStart = content.utf8.index(content.startIndex, offsetBy: segment.offset)
            return Array(previous.segments.dropLast()) + split(content, from: fenceStart)
        }
        let codeLines = lines.map { line in
            line.dropFirst(line.prefix(open.fence.indentation).prefix { $0 == " " }.count)
        }
        guard let lastLine = lines.last, let lastCodeLine = codeLines.last else { return nil }
        let prefixEnd = previousCode.utf8.index(previousCode.endIndex, offsetBy: -open.lastCodeLineBytes)
        var code = String(previousCode[..<prefixEnd])
        code.append(contentsOf: codeLines.joined(separator: "\n"))
        let updated = MarkdownSegment(
            block: .codeBlock(language: language, code: code, isClosed: false,
                              lineCount: previousLineCount - 1 + lines.count),
            offset: segment.offset,
            openFence: OpenMarkdownFence(fence: open.fence,
                lastLineOffset: content.utf8.distance(from: content.startIndex, to: lastLine.startIndex),
                lastCodeLineBytes: lastCodeLine.utf8.count))
        return Array(previous.segments.dropLast()) + [updated]
    }

    private static func render(_ block: MarkdownBlock, optimistic: Bool, isStreaming: Bool,
                               previous: (block: MarkdownBlock, content: RenderedMarkdownBlock.Content)?,
                               highlighting: inout SyntaxHighlightCache) -> RenderedMarkdownBlock.Content {
        func parsed(_ text: String) -> AttributedString {
            let source = optimistic ? StreamingMarkdownTail.closing(text) : text
            return MarkdownInlineRendering.parse(source)
        }
        func inline(_ text: String) -> AttributedString {
            linkingImages(parsed(text)).annotatingLinkChips()
        }
        switch block {
        case .htmlVisual(let url, let title):
            return .htmlVisual(url: url, title: title)
        case .heading(let level, let text):
            return .heading(level: level, content: inline(text))
        case .paragraph(let text):
            let content = parsed(text)
            if let images = MarkdownInlineRendering.standaloneImages(content) { return .images(images) }
            return .paragraph(content: linkingImages(content).annotatingLinkChips())
        case .quote(let text):
            return .quote(content: inline(text))
        case .bulletList(let items):
            return .bulletList(items: items.map { RenderedListItem(content: inline($0.text), level: $0.level) })
        case .codeBlock(let language, let code, let isClosed, let lineCount):
            // A closed fence is stable even while later prose is streaming.
            // At end-of-turn an unclosed fence still deserves a render attempt.
            let isSettled = isClosed || !isStreaming
            if language?.split(whereSeparator: \.isWhitespace).first?.lowercased() == "mermaid" {
                return .mermaid(source: code, isComplete: isSettled)
            }
            let presentation = RenderedCodePresentation(code: code, language: language, lineCount: lineCount,
                isStreaming: !isSettled, highlighting: &highlighting)
            return .codeBlock(language: language, code: code, presentation: presentation)
        case .table(let headers, let alignments, let rows):
            let renderedHeaders: [AttributedString]
            let renderedRows: [[AttributedString]]
            if let previous,
               case .table(let oldHeaders, _, let oldRows) = previous.block,
               case .table(let oldRenderedHeaders, _, let oldRenderedRows, _) = previous.content {
                renderedHeaders = headers == oldHeaders ? oldRenderedHeaders : headers.map(inline)
                renderedRows = rows.enumerated().map { index, row in
                    if index < oldRows.count, row == oldRows[index] { return oldRenderedRows[index] }
                    return row.map(inline)
                }
            } else {
                renderedHeaders = headers.map(inline)
                renderedRows = rows.map { $0.map(inline) }
            }
            return .table(headers: renderedHeaders, alignments: alignments, rows: renderedRows,
                          columnCharacterCounts: columnCharacterCounts([renderedHeaders] + renderedRows))
        }
    }

    private static func linkingImages(_ content: AttributedString) -> AttributedString {
        var content = content
        for (url, range) in content.runs[\.imageURL].reversed() {
            guard let url, content[range].link == nil else { continue }
            var alt = AttributedString(MarkdownInlineRendering.imageAlt(String(content[range].characters), url: url))
            alt.link = url
            content.replaceSubrange(range, with: alt)
        }
        return content
    }

    private static func columnCharacterCounts(_ rows: [[AttributedString]]) -> [Int] {
        var counts: [Int] = []
        for row in rows {
            for (column, cell) in row.enumerated() {
                let count = cell.characters.count
                if column < counts.count { counts[column] = max(counts[column], count) } else { counts.append(count) }
            }
        }
        return counts
    }

    private static func split(_ content: String, from start: String.Index) -> [MarkdownSegment] {
        let span = PerfBuild.span("markdown.split")
        defer { span.end() }
        var blocks: [MarkdownSegment] = []
        var currentListItems: [MarkdownListLine] = []
        var listStart = 0
        var paragraphLines: [Substring] = []
        var paragraphStart = 0

        let lines = content[start...].split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        func append(_ block: MarkdownBlock, startingAt line: Int) {
            let offset = content.utf8.distance(from: content.startIndex, to: lines[line].startIndex)
            blocks.append(MarkdownSegment(block: block, offset: offset))
        }
        func flushList() {
            guard !currentListItems.isEmpty else { return }
            append(.bulletList(items: currentListItems), startingAt: listStart)
            currentListItems = []
        }
        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(.paragraph(text: paragraphText(paragraphLines)), startingAt: paragraphStart)
            paragraphLines = []
        }

        var i = 0

        while i < lines.count {
            let line = lines[i]

            if let image = MarkdownInlineRendering.standaloneVisual(String(line)) {
                flushList()
                flushParagraph()
                append(.htmlVisual(url: image.url, title: image.alt), startingAt: i)
                i += 1
                continue
            }

            if let fence = MarkdownFence(line) {
                flushList()
                flushParagraph()

                let start = i
                var codeLines: [Substring] = []
                i += 1
                while i < lines.count && !fence.closes(lines[i]) {
                    let indent = lines[i].prefix(fence.indentation).prefix { $0 == " " }.count
                    codeLines.append(lines[i].dropFirst(indent))
                    i += 1
                }
                append(.codeBlock(language: fence.language,
                                  code: codeLines.joined(separator: "\n"),
                                  isClosed: i < lines.count,
                                  lineCount: max(1, codeLines.count)), startingAt: start)
                if i == lines.count, let lastLine = lines.last, let lastCodeLine = codeLines.last {
                    blocks[blocks.count - 1].openFence = OpenMarkdownFence(fence: fence,
                        lastLineOffset: content.utf8.distance(from: content.startIndex, to: lastLine.startIndex),
                        lastCodeLineBytes: lastCodeLine.utf8.count)
                }
                i += 1
                continue
            }

            // Table detection: header row | separator row | data rows
            if isTableRow(line),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1])
            {
                flushList()
                flushParagraph()

                let start = i
                let headers = parseTableCells(line)
                let alignments = parseTableAlignments(lines[i + 1])
                var rows: [[String]] = []
                i += 2
                while i < lines.count, isTableRow(lines[i]), MarkdownInlineRendering.standaloneVisual(String(lines[i])) == nil {
                    rows.append(parseTableCells(lines[i]))
                    i += 1
                }
                append(.table(headers: headers, alignments: alignments, rows: rows), startingAt: start)
                continue
            }

            if quotedText(line) != nil {
                flushList()
                flushParagraph()

                let start = i
                var quoted: [Substring] = []
                while i < lines.count, let text = quotedText(lines[i]) {
                    quoted.append(text)
                    i += 1
                }
                let paragraphs = quoted.split(whereSeparator: isBlank).map { paragraphText(Array($0)) }
                append(.quote(text: paragraphs.joined(separator: "\n\n")), startingAt: start)
                continue
            }

            if let block = heading(line) {
                flushList()
                flushParagraph()
                append(block, startingAt: i)
            } else if let item = listLine(line) {
                flushParagraph()
                if currentListItems.isEmpty { listStart = i }
                currentListItems.append(item)
            } else if isStandaloneParagraphLine(line) {
                flushList()
                flushParagraph()
                append(.paragraph(text: String(line)), startingAt: i)
            } else if !isBlank(line) {
                flushList()
                if paragraphLines.isEmpty { paragraphStart = i }
                paragraphLines.append(line)
            } else {
                flushList()
                flushParagraph()
            }

            i += 1
        }

        flushList()
        flushParagraph()

        return blocks
    }

    private static func paragraphText(_ lines: [Substring]) -> String {
        var result = ""
        for (index, source) in lines.enumerated() {
            let line = index == 0 ? source : source.drop(while: { $0 == " " || $0 == "\t" })
            guard index < lines.count - 1 else {
                result.append(contentsOf: line)
                break
            }
            let spaces = line.reversed().prefix { $0 == " " }.count
            if spaces >= 2 {
                let prefix = line.dropLast(spaces)
                result.append(contentsOf: prefix)
                if !prefix.reversed().prefix(while: { $0 == "\\" }).count.isMultiple(of: 2) {
                    result.append("\\")
                }
                result.append("\n")
            } else if !line.reversed().prefix(while: { $0 == "\\" }).count.isMultiple(of: 2) {
                result.append(contentsOf: line.dropLast())
                result.append("\n")
            } else {
                result.append(contentsOf: line.dropLast(line.reversed().prefix { $0 == " " || $0 == "\t" }.count))
                result.append(" ")
            }
        }
        return result
    }

    private static func heading(_ line: Substring) -> MarkdownBlock? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let text = line.dropFirst(level)
        guard text.first?.isWhitespace ?? true else { return nil }
        return .heading(level: level, text: String(text.drop(while: \.isWhitespace)))
    }

    private static func listLine(_ line: Substring) -> MarkdownListLine? {
        let indentation = line.prefix(while: \.isWhitespace)
        let marker = line[indentation.endIndex...]
        guard marker.first == "-" || marker.first == "*", marker.dropFirst().first?.isWhitespace == true else {
            return nil
        }
        let body = marker.dropFirst(2)
        guard !body.isEmpty else { return nil }
        let text = body.drop(while: \.isWhitespace)
        let width = indentation.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        return MarkdownListLine(text: String(text.isEmpty ? body.suffix(1) : text), level: min(3, width / 2))
    }

    private static func isStandaloneParagraphLine(_ line: Substring) -> Bool {
        let marker = line.drop(while: \.isWhitespace)
        guard let first = marker.first else { return false }
        switch first {
        case "+":
            return marker.dropFirst().first?.isWhitespace == true
        case "=", "-":
            return marker.drop { $0 == first }.allSatisfy(\.isWhitespace)
        case "*", "_":
            let rule = marker.prefix { $0 == first || $0 == " " || $0 == "\t" }
            return rule.count { $0 == first } >= 3 && marker[rule.endIndex...].allSatisfy(\.isWhitespace)
        default:
            let digits = marker.prefix(while: \.isNumber)
            let delimiter = marker[digits.endIndex...]
            return (1...9).contains(digits.count) && (delimiter.first == "." || delimiter.first == ")")
                && delimiter.dropFirst().first?.isWhitespace == true
        }
    }

    private static func quotedText(_ line: Substring) -> Substring? {
        let marker = line.drop(while: \.isWhitespace)
        guard marker.first == ">" else { return nil }
        let text = marker.dropFirst()
        return text.first == " " ? text.dropFirst() : text
    }

    private static func isBlank(_ line: Substring) -> Bool {
        line.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains)
    }

    private static func isTableRow(_ line: Substring) -> Bool {
        line.contains("|")
    }

    private static func isTableSeparator(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Separator row: cells contain only dashes, colons, spaces, and pipes
        let stripped = trimmed.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty && trimmed.contains("-")
    }

    private static func parseTableCells(_ line: Substring) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        return trimmed.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func parseTableAlignments(_ line: Substring) -> [TableAlignment] {
        parseTableCells(line).map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let left = trimmed.hasPrefix(":")
            let right = trimmed.hasSuffix(":")
            if left && right { return .center }
            if right { return .trailing }
            return .leading
        }
    }
}

extension SyntaxHighlighting {
    static func highlight(_ code: String, language: String?) -> AttributedString {
        var attributedString = AttributedString(code)
        for token in tokens(in: code, language: language) {
            guard let range = Range(token.range, in: attributedString) else { continue }
            attributedString.setSyntaxColor(token.kind, in: range)
        }
        return attributedString
    }
}

struct RenderedCodePresentation: Sendable, Equatable {
    static let previewLineCount = 24
    let lineCount: Int
    let isStreaming: Bool
    let content: AttributedString
    let preview: AttributedString

    var isCollapsible: Bool { lineCount > 40 }
    var showsStreamingTail: Bool { isStreaming && lineCount > Self.previewLineCount }

    init(code: String, language: String?, lineCount: Int, isStreaming: Bool,
         highlighting: inout SyntaxHighlightCache) {
        let span = PerfBuild.span("markdown.codePresentation")
        defer { span.end() }
        self.lineCount = lineCount
        self.isStreaming = isStreaming
        if isStreaming {
            PerfBuild.count("code.tailRender")
            var start = code.endIndex
            var newlines = 0
            while start > code.startIndex {
                let prior = code.index(before: start)
                if code[prior] == "\n" {
                    newlines += 1
                    if newlines == Self.previewLineCount { break }
                }
                start = prior
            }
            content = AttributedString(String(code[start...]))
            preview = content
        } else {
            PerfBuild.count("code.fullRender")
            content = highlighting.highlight(code, language: language)
            let lines = code.split(separator: "\n", maxSplits: Self.previewLineCount,
                                   omittingEmptySubsequences: false)
            let prefixCount = lines.prefix(Self.previewLineCount).joined(separator: "\n").count
            let end = content.characters.index(content.startIndex, offsetBy: prefixCount)
            preview = AttributedString(content[content.startIndex..<end])
        }
    }
}
