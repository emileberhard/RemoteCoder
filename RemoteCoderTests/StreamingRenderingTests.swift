import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

struct StreamingRenderingTests {
    private func render(_ text: String, previous: RenderedMessage? = nil,
                        streaming: Bool = true) -> RenderedMessage {
        var highlighting = SyntaxHighlightCache()
        return RenderedMessage.render(text: text, inline: nil, isStreaming: streaming, previous: previous,
                                      highlighting: &highlighting)
    }

    @Test func htmlVisualsHaveTheirOwnStableBlockAcrossStreamingChunks() throws {
        let digest = String(repeating: "a", count: 64)
        let source = "The key result.\n![Comparison](rc-visual:" + digest + ")\nThe reply continues."
        let final = render(source, streaming: false)
        #expect(final.containsHTMLVisual)
        #expect(final.blocks.count == 3)
        guard case .htmlVisual(let url, let title) = final.blocks[1].content else {
            Issue.record("Expected an HTML visual block"); return
        }
        #expect(url.absoluteString == "rc-visual:" + digest)
        #expect(title == "Comparison")
        #expect(final.plainText == "The key result.\n\nComparison\n\nThe reply continues.")
        var previous: RenderedMessage?
        var partial = ""
        for character in source {
            partial.append(character)
            previous = render(partial, previous: previous)
        }
        let streamed = render(source, previous: previous, streaming: false)
        #expect(streamed.containsHTMLVisual)
        #expect(Self.shape(streamed.blocks) == Self.shape(final.blocks))
        let extended = render(source + " More detail.", previous: streamed)
        #expect(streamed.blocks[1] == extended.blocks[1])
        let code = render("```markdown\n![Comparison](rc-visual:" + digest + ")\n```", streaming: false)
        #expect(!code.containsHTMLVisual)
        guard case .codeBlock = code.blocks[0].content else {
            Issue.record("A code sample must remain copyable code"); return
        }
    }

    @Test func headingReservesItsKindBeforeTextArrives() throws {
        guard case .heading(let level, let content) = try #require(render("## ").blocks.first).content else {
            Issue.record("A partial heading must not become a plain paragraph"); return
        }
        #expect(level == 2)
        #expect(content.characters.isEmpty)
    }

    @Test func nestedListsKeepIndentation() throws {
        guard case .bulletList(let items) = try #require(render("- one\n  - two\n\t- tab\n        - deep").blocks.first).content else {
            Issue.record("Expected a list"); return
        }
        #expect(items.map(\.level) == [0, 1, 1, 3])
        #expect(items.map { String($0.content.characters) } == ["one", "two", "tab", "deep"])
    }

    @Test(arguments: ["**bold", "*italic", "`code", "~~deleted", "***both", "**bold *nested", "> **quoted"])
    func unfinishedFormattingDoesNotExposeMarkers(_ input: String) throws {
        let content = try #require(render(input).blocks.first?.inlines.first)
        #expect(!String(content.characters).contains("*"))
        #expect(!String(content.characters).contains("`"))
        #expect(!String(content.characters).contains("~"))
    }

    @Test(arguments: ["**bold**", "*italic*", "`a * b`", "~~deleted~~", "2 * 3", #"\*literal\*"#, "A ~~ B"])
    func balancedOrLiteralTextIsNotRewritten(_ input: String) {
        #expect(StreamingMarkdownTail.closing(input) == input)
    }

    @Test func codeAndEscapesDoNotParticipateInEmphasisBalancing() {
        #expect(StreamingMarkdownTail.closing("**bold `a * b") == "**bold `a * b`**")
        #expect(StreamingMarkdownTail.closing(#"**bold \*"#) == #"**bold \***"#)
        #expect(StreamingMarkdownTail.closing("``a ` b") == "``a ` b``")
        #expect(StreamingMarkdownTail.closing("A *") == "A ")
    }

    @Test func finishedMessagesKeepLiteralUnmatchedMarkers() throws {
        let content = try #require(render("**unfinished", streaming: false).blocks.first?.inlines.first)
        #expect(String(content.characters) == "**unfinished")
    }

    @Test func onlyTheLiveTailGetsOptimisticParsing() {
        let result = render("**unfinished\n\n*tail")
        #expect(result.blocks.flatMap(\.inlines).map { String($0.characters) } == ["**unfinished", "tail"])
    }

    @Test func onlyStreamedTextReveals() {
        let first = render("Hello")
        let terminal = render("Hello world", previous: first, streaming: false)
        #expect(first.arrival.targets == [.text(StreamingRevealTextSlot(block: 0, slot: 0), utf16: 0..<5)])
        #expect(terminal.arrival.targets == [.text(StreamingRevealTextSlot(block: 0, slot: 0), utf16: 6..<11)])
        #expect(render("Hello world", streaming: false).arrival.targets.isEmpty)
        #expect(render("Hello world!", previous: render("Hello world", streaming: false), streaming: false)
            .arrival.targets.isEmpty)
    }

    @Test func arrivalsCoverOnlyNewWordsAndNewBlocks() {
        let slot = { StreamingRevealTextSlot(block: $0, slot: $1) }
        let previous = render("Intro wor\n\n- one\n- tw")
        let current = render("Intro world again\n\n- one\n- two\n- three\n\n```\nlet x\n```", previous: previous)
        #expect(current.arrival.targets == [
            .text(slot(0, 0), utf16: 9..<12), .text(slot(0, 0), utf16: 12..<17),
            .text(slot(1, 1), utf16: 2..<3), .text(slot(1, 2), utf16: 0..<5), .block(2),
        ])
        #expect(current.arrival.continuations == [
            .text(slot(0, 0), utf16: 9..<12), .text(slot(1, 1), utf16: 2..<3),
        ])
        let grown = render("Intro world again\n\n- one\n- two\n- three\n\n```\nlet x = 1\n```", previous: current)
        #expect(grown.arrival.targets.isEmpty)
        #expect(grown.arrival.carries(.block(2)))
        #expect(grown.arrival.carries(.text(slot(0, 0), utf16: 12..<17)))
    }

    @MainActor @Test func revealCoversMatchMarkedRunsAcrossParagraphsWrapsAndReplacements() throws {
        let segments: [(text: String, mark: Int?)] = [
            ("alpha ", nil), ("beta", 6), ("\ngamma ", nil), ("\u{00A0}", 17), ("ab", 17), (" ", 17),
            ("delta epsilon zeta ", 22), ("eta theta", nil),
        ]
        let spans = [StreamingRevealSpan(utf16: 6..<10, begin: 1), StreamingRevealSpan(utf16: 17..<22, begin: 2),
                     StreamingRevealSpan(utf16: 22..<41, begin: 3)]
        let source = AttributedString("alpha beta\ngamma LINK delta epsilon zeta eta theta")
        let map = StreamingRevealLayoutMap(text: source, spans: spans,
                                           replacements: [.init(source: 17..<21, length: 3)])
        let plain = try #require(Self.layout(of: Text(segments.map(\.text).joined())))
        let marked = try #require(Self.layout(of: segments.reduce(Text(verbatim: "")) { text, segment in
            let piece = segment.mark.map { Text(segment.text).customAttribute(RevealOracleMark(id: $0)) } ?? Text(segment.text)
            return Text("\(text)\(piece)")
        }))
        var expected: [Int: [CGRect]] = [:]
        for line in marked {
            var lineRects: [Int: CGRect] = [:]
            for run in line {
                guard let mark = run[RevealOracleMark.self] else { continue }
                let bounds = run.typographicBounds.rect
                let rect = CGRect(x: bounds.minX, y: line.typographicBounds.rect.minY, width: bounds.width,
                                  height: line.typographicBounds.rect.height)
                lineRects[mark.id] = lineRects[mark.id]?.union(rect) ?? rect
            }
            for (id, rect) in lineRects { expected[id, default: []].append(rect) }
        }
        #expect(expected[22]?.count ?? 0 > 1)
        for layout in [plain, marked] {
            let covers = StreamingRevealCover.covers(for: map, in: layout, at: .zero)
            #expect(covers.map(\.id) == [6, 17, 22])
            for cover in covers {
                let reference = expected[cover.id] ?? []
                #expect(cover.rects.count == reference.count)
                #expect(zip(cover.rects, reference).allSatisfy { lhs, rhs in
                    [lhs.minX - rhs.minX, lhs.minY - rhs.minY, lhs.width - rhs.width, lhs.height - rhs.height]
                        .allSatisfy { abs($0) < 0.5 }
                })
            }
        }
    }

    @MainActor private static func layout(of text: Text) -> Text.Layout? {
        var layout: Text.Layout?
        let renderer = ImageRenderer(content: text.frame(width: 140, alignment: .leading)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                let _ = layout = layouts.first?.layout
                Color.clear
            })
        _ = renderer.uiImage
        return layout
    }

    @Test func revealsStaggerWordsAndCarryOnlyFadingUnchangedText() {
        let first = render("One two three").publishing(after: nil, at: 10)
        let spans = first.reveal.block(0).spans(slot: 0)
        #expect(spans.map(\.utf16) == [0..<4, 4..<8, 8..<13])
        #expect(zip(spans.map(\.begin), [10, 10.07, 10.14]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(first.reveal.end.map { abs($0 - 10.64) < 1e-9 } == true)
        let continued = render("One two threefold four", previous: first).publishing(after: first, at: 10.2)
        let next = continued.reveal.block(0).spans(slot: 0)
        #expect(next.map(\.utf16) == [0..<4, 4..<8, 8..<13, 13..<18, 18..<22])
        #expect(next[3].begin == spans[2].begin)
        #expect(abs(next[4].begin - 10.21) < 1e-9)
        let corrected = render("Uno", previous: continued).publishing(after: continued, at: 10.3)
        #expect(corrected.reveal.block(0).spans(slot: 0).map(\.utf16) == [0..<3])
        let settled = render("Uno", previous: corrected, streaming: false).publishing(after: corrected, at: 11)
        #expect(settled.reveal == .settled)
    }

    @Test func inlineStylesAndLinksSurvivePreparation() throws {
        let content = try #require(render("**bold** *italic* `code` [link](https://example.org)").blocks.first?.inlines.first)
        #expect(content.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(content.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        #expect(content.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(content.runs.contains { $0.link == URL(string: "https://example.org") })
    }

    @Test func imagesBecomeBlocksOnlyWhenTheyStandAlone() throws {
        let chart = try #require(URL(string: "file:///tmp/chart.png"))
        let blocks = render("![Chart](file:///tmp/chart.png)\n\n![](plots/a.png) ![B](file:///tmp/b.png)\n\n"
                            + "See ![Chart](file:///tmp/chart.png) here", streaming: false).blocks
        try #require(blocks.count == 3)
        guard case .images(let single) = blocks[0].content, case .images(let pair) = blocks[1].content else {
            Issue.record("Standalone images did not become image blocks")
            return
        }
        #expect(single == [MarkdownImage(url: chart, alt: "Chart")])
        #expect(pair.map(\.alt) == ["a.png", "B"])
        let prose = try #require(blocks[2].inlines.first)
        #expect(String(prose.characters) == "See Chart here")
        #expect(prose.runs.contains { $0.link == chart && String(prose[$0.range].characters) == "Chart" })
    }

    @Test(arguments: [("Chart", true), ("a[b", false), ("a[b]", true), ("a|b", true)], [false, true])
    func visualPlacementMatchesRenderedImages(label: (String, Bool), afterTable: Bool) throws {
        let digest = String(repeating: "a", count: 64)
        let embed = "![\(label.0)](rc-visual:\(digest))"
        let source = (afterTable ? "| Column |\n| --- |\n" : "") + embed
        let rendered = render(source, streaming: false).blocks.compactMap { block -> HTMLVisualReference? in
            guard case .htmlVisual(let url, _) = block.content else { return nil }
            return HTMLVisualReference(url: url)
        }
        #expect(rendered == HTMLVisualReference.standaloneReferences(inMarkdown: source))
        #expect(rendered.count == (label.1 ? 1 : 0))
    }

    @Test(arguments: ["\n", "\r\n", "\r", "\u{2028}"])
    func wrappedProseFormsOneParagraphUntilABlankLine(separator: String) {
        let source = ["First **bold", "second** line.", "", "Next paragraph.", "Still here."].joined(separator: separator)
        let blocks = render(source, streaming: false).blocks
        #expect(blocks.count == 2)
        #expect(blocks.flatMap(\.inlines).map { String($0.characters) } == [
            "First bold second line.", "Next paragraph. Still here."
        ])
        #expect(blocks.first?.inlines.first?.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        } == true)
    }

    @Test(arguments: [
        ("First  \nsecond\nthird", "First\nsecond third"),
        ("First\\\nsecond\nthird", "First\nsecond third"),
        ("First  \r\nsecond\nthird", "First\nsecond third"),
        ("First\\\r\nsecond\nthird", "First\nsecond third"),
        ("First \n  second\\\\\nthird", "First second\\ third"),
        ("First\\  \nsecond", "First\\\nsecond"),
    ])
    func softAndHardBreaksStayInsideOneParagraph(source: String, expected: String) throws {
        let result = render(source, streaming: false)
        #expect(result.blocks.count == 1)
        let content = try #require(result.blocks.first?.inlines.first)
        #expect(String(content.characters) == expected)
    }

    @Test func inlineFormattingSpansSoftAndHardBreaks() throws {
        let result = render("**First\nsecond  \nthird**", streaming: false)
        let content = try #require(result.blocks.first?.inlines.first)
        #expect(String(content.characters) == "First second\nthird")
        let bold = content.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(content[$0.range].characters) }.joined()
        #expect(bold.filter { !$0.isWhitespace } == "Firstsecondthird")
    }

    @Test func paragraphBoundariesPreserveStructuralBlocks() throws {
        let source = """
            Intro
            continued
            ## Heading
            More prose
            continued
            - one
              - two
            After the list
            continued
            ```swift
            let first = 1
            let second = 2
            ```
            Before the table
            continued
            | Name | Value |
            | --- | --- |
            | One | Two |
            After the table
            continued
            """
        let blocks = render(source, streaming: false).blocks
        try #require(blocks.count == 9)
        guard case .heading(level: 2, _) = blocks[1].content,
              case .bulletList(let items) = blocks[3].content,
              case .codeBlock(let language, let code, _) = blocks[5].content,
              case .table(let headers, let alignments, let rows, let columnCharacterCounts) = blocks[7].content else {
            Issue.record("Structural blocks must interrupt prose without absorbing adjacent paragraphs"); return
        }
        #expect(items.map(\.level) == [0, 1])
        #expect(language == "swift")
        #expect(code == "let first = 1\nlet second = 2")
        #expect(headers.map { String($0.characters) } == ["Name", "Value"])
        #expect(alignments == [.leading, .leading])
        #expect(rows.map { $0.map { String($0.characters) } } == [["One", "Two"]])
        #expect(columnCharacterCounts == [4, 5])
        #expect(blocks.compactMap { block -> String? in
            guard case .paragraph(let content) = block.content else { return nil }
            return String(content.characters)
        } == ["Intro continued", "More prose continued", "After the list continued", "Before the table continued", "After the table continued"])
    }

    @Test(arguments: ["1. Build\n2. Install", "1) Build\n2) Install", "+ Build\n+ Install"])
    func unparsedMarkdownStructuresKeepSeparateLines(structure: String) {
        let result = render("Intro\n" + structure + "\nAfter\ncontinued", streaming: false)
        #expect(result.blocks.flatMap(\.inlines).map { String($0.characters) }
            == ["Intro"] + structure.components(separatedBy: "\n") + ["After continued"])
    }

    @Test(arguments: ["---", "===", "***", "___", "_ _ _"])
    func thematicAndSetextMarkersInterruptProse(marker: String) throws {
        let result = render("Before\n" + marker + "\nAfter\ncontinued", streaming: false)
        try #require(result.blocks.count == 3)
        #expect(result.blocks.first?.inlines.map { String($0.characters) } == ["Before"])
        #expect(result.blocks.last?.inlines.map { String($0.characters) } == ["After continued"])
    }

    @Test(arguments: [
        ("# Title", ["p: Intro", "h1: Title", "p: After"]),
        ("###### Six", ["p: Intro", "h6: Six", "p: After"]),
        ("##", ["p: Intro", "h2: ", "p: After"]),
        ("##\t Tabbed", ["p: Intro", "h2: Tabbed", "p: After"]),
        ("#\u{A0}Unicode space", ["p: Intro", "h1: Unicode space", "p: After"]),
        ("####### Seven", ["p: Intro ####### Seven After"]),
        ("#Tight", ["p: Intro #Tight After"]),
        ("- item", ["p: Intro", "list [0]: item", "p: After"]),
        ("\t* tab", ["p: Intro", "list [1]: tab", "p: After"]),
        ("\u{3000}\u{3000}- wide", ["p: Intro", "list [1]: wide", "p: After"]),
        ("-\u{A0}unicode", ["p: Intro", "list [0]: unicode", "p: After"]),
        ("* * *", ["p: Intro", "list [0]: * *", "p: After"]),
        ("-tight", ["p: Intro -tight After"]),
        ("- ", ["p: Intro", "p: - ", "p: After"]),
        ("1. Build", ["p: Intro", "p: 1. Build", "p: After"]),
        ("  123456789) Nine", ["p: Intro", "p:   123456789) Nine", "p: After"]),
        ("1234567890. Ten", ["p: Intro 1234567890. Ten After"]),
        ("٣. Arabic-Indic", ["p: Intro", "p: ٣. Arabic-Indic", "p: After"]),
        ("1.Tight", ["p: Intro 1.Tight After"]),
        ("+\tPlus", ["p: Intro", "p: +\tPlus", "p: After"]),
        ("+Tight", ["p: Intro +Tight After"]),
        ("> Quote", ["p: Intro", "quote: Quote", "p: After"]),
        ("  >Tight", ["p: Intro", "quote: Tight", "p: After"]),
        ("=\u{3000}", ["p: Intro", "p: =\u{3000}", "p: After"]),
        ("  ---  ", ["p: Intro", "p:   ---  ", "p: After"]),
        ("-- -", ["p: Intro -- - After"]),
        ("_\t_ _", ["p: Intro", "p: _\t_ _", "p: After"]),
        ("__", ["p: Intro __ After"]),
        ("\u{A0}\t", ["p: Intro", "p: After"]),
        ("\u{200B}", ["p: Intro", "p: After"]),
    ])
    func lineMarkersKeepTheirBlockKinds(line: String, expected: [String]) {
        #expect(Self.outline(render("Intro\n\(line)\nAfter", streaming: false).blocks) == expected)
    }

    @Test func consecutiveQuoteLinesFormOneQuote() {
        let source = "Intro\n> A smooth **stream**\n>is useful\n>\n> Second paragraph\nAfter"
        #expect(Self.outline(render(source, streaming: false).blocks) == [
            "p: Intro", "quote: A smooth stream is useful\n\nSecond paragraph", "p: After",
        ])
    }

    @Test(arguments: [1, 2, 3, 7, 16, 61])
    func streamedChunksParseLikeTheWholeText(chunk: Int) {
        let scalars = Array(Self.streamingFixture.unicodeScalars)
        var previous: RenderedMessage?
        var end = 0
        while end < scalars.count {
            end = min(scalars.count, end + chunk)
            var prefix = String.UnicodeScalarView()
            prefix.append(contentsOf: scalars[..<end])
            let text = String(prefix)
            let streamed = render(text, previous: previous)
            #expect(Self.shape(streamed.blocks) == Self.shape(render(text).blocks), "after \(end) scalars")
            previous = streamed
        }
        let terminal = render(Self.streamingFixture, previous: previous, streaming: false)
        #expect(Self.shape(terminal.blocks) == Self.shape(render(Self.streamingFixture, streaming: false).blocks))
    }

    @Test func blocksCompareByRenderSoOnlyChangedBlocksDiffer() {
        let first = render("a\n\nb")
        let second = render("a\n\nbc", previous: first)
        #expect(second.blocks[0] == first.blocks[0])
        #expect(second.blocks[1] != first.blocks[1])
        #expect(render("a\n\nb").blocks[0] != first.blocks[0])
    }

    @Test func settledWrappedParagraphsKeepTheirRenderVersions() {
        let source = "First\r\nwrapped.\r\n\r\nSecond\r\nwrapped.\r\n\r\nTail"
        let first = render(source)
        let second = render(source + " grows", previous: first)
        #expect(second.blocks.count == 3)
        #expect(Array(second.blocks.prefix(2)) == Array(first.blocks.prefix(2)))
        #expect(second.blocks.last != first.blocks.last)
        #expect(Self.shape(second.blocks) == Self.shape(render(source + " grows").blocks))
    }

    @Test func tableReplacementsAndCompletionKeepCurrentTextAndFormatting() throws {
        let first = "| Name | Value |\n| --- | --- |\n| Old | **unfinished |\n| Extra | cell |"
        let replacement = "| Label | Value |\n| --- | --- |\n| New | **unfinished |"
        let initial = render(first)
        let updated = render(replacement, previous: initial)
        let settled = render(replacement, previous: updated, streaming: false)
        guard case .table(let headers, _, let rows, _) = try #require(settled.blocks.first).content else {
            Issue.record("Expected a table")
            return
        }
        #expect(headers.map { String($0.characters) } == ["Label", "Value"])
        #expect(rows.map { $0.map { String($0.characters) } } == [["New", "**unfinished"]])
        #expect(rows[0][1].runs.allSatisfy { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) != true })
    }

    @Test func openFenceStaysPlainWhileStreamingAndHighlightsOnceSettled() {
        let open = "```swift\nlet x = 1"
        let highlighted = [ColoredRun("let", .systemPink), ColoredRun("1", .systemOrange)]
        #expect(Self.codeColors(render(open)) == [])
        #expect(Self.codeColors(render(open + "\n```")) == highlighted)
        #expect(Self.codeColors(render(open, streaming: false)) == highlighted)
    }

    @Test(arguments: [true, false])
    func longStreamingCodeKeepsFullCopyButOnlyAttributesTheTail(closesFence: Bool) throws {
        let lines = (1...80).map { "let value\($0) = \($0)" }
        let first = render("```swift\n" + lines.prefix(50).joined(separator: "\n"))
        let source = "```swift\n" + lines.joined(separator: "\n")
        let streamed = render(source, previous: first)
        let block = try #require(streamed.blocks.first)
        let presentation = try #require(block.codePresentation)
        #expect(presentation.lineCount == 80)
        #expect(presentation.showsStreamingTail)
        #expect(String(presentation.content.characters) == lines.suffix(24).joined(separator: "\n"))
        #expect(streamed.plainText == lines.joined(separator: "\n"))
        #expect(Self.codeColors(streamed) == [])

        let terminalSource = source + (closesFence ? "\n```" : "")
        let settled = render(terminalSource, previous: streamed, streaming: closesFence)
        let history = render(terminalSource, streaming: false)
        let settledPresentation = try #require(settled.blocks.first?.codePresentation)
        #expect(!settledPresentation.isStreaming)
        #expect(settledPresentation.isCollapsible)
        #expect(String(settledPresentation.preview.characters) == lines.prefix(24).joined(separator: "\n"))
        #expect(Self.shape(settled.blocks) == Self.shape(history.blocks))
        #expect(settledPresentation.preview == history.blocks.first?.codePresentation?.preview)
    }

    @Test(arguments: ["\n", "\r\n", "\r", "\u{2028}"])
    func openFenceSuffixPreservesIndentationAndFallsBackForReplacements(separator: String) throws {
        let lines = (1...50).map { "  let café\($0) = \"👩🏽‍💻\"" }
        let prefix = "Intro" + separator + separator + "  ````swift" + separator
        let firstSource = prefix + lines.prefix(30).joined(separator: separator)
        let first = render(firstSource)
        let source = prefix + lines.joined(separator: separator)
        let streamed = render(source, previous: first)
        #expect(Self.shape(streamed.blocks) == Self.shape(render(source).blocks))
        #expect(streamed.blocks.last?.codePresentation?.lineCount == 50)

        let replacement = source.replacingOccurrences(of: "café1 ", with: "changed ")
        let replaced = render(replacement, previous: streamed)
        #expect(Self.shape(replaced.blocks) == Self.shape(render(replacement).blocks))
        let shortened = render(firstSource, previous: replaced)
        #expect(Self.shape(shortened.blocks) == Self.shape(first.blocks))

        let closed = source + separator + "  ```" + separator + "  ````" + separator + "After"
        let settled = render(closed, previous: streamed, streaming: false)
        #expect(Self.shape(settled.blocks) == Self.shape(render(closed, streaming: false).blocks))
        #expect(settled.blocks.dropLast().last?.codePresentation?.lineCount == 51)
    }

    @Test func highlightingColorsEachTokenClassOutsideStringsAndComments() {
        let code = """
            let letter = "let 42" // var 7
            func f(x: inout Int) -> Int { return 3.14 }
            """
        #expect(Self.colors(SyntaxHighlighting.highlight(code, language: "swift")) == [
            ColoredRun("let", .systemPink), ColoredRun(#""let 42""#, .systemGreen), ColoredRun("// var 7", .systemGray),
            ColoredRun("func", .systemPink), ColoredRun("inout", .systemPink), ColoredRun("return", .systemPink),
            ColoredRun("3.14", .systemOrange),
        ])
    }

    private struct ColoredRun: Equatable {
        let text: String
        let color: UIColor
        init(_ text: String, _ color: UIColor) { self.text = text; self.color = color }
    }

    private static func colors(_ text: AttributedString) -> [ColoredRun] {
        text.runs[AttributeScopes.UIKitAttributes.ForegroundColorAttribute.self].compactMap { color, range in
            color.map { ColoredRun(String(text[range].characters), $0) }
        }
    }

    private static func codeColors(_ rendered: RenderedMessage) -> [ColoredRun]? {
        guard case .codeBlock(_, _, let presentation) = rendered.blocks.first?.content else { return nil }
        return colors(presentation.content)
    }

    private static let streamingFixture = """
        # Title 👩🏽‍💻 with **bold**

        Intro with `code`, a line\u{2028}separator and a [link](https://example.org).
        Hard break follows:\u{20}\u{20}
        Backslash break follows:\\
        Last line of this paragraph.

        Steps:
        1. Build
        2. Install
        + Additional item
        > Quoted text
        > Continued quote
        Section text
        ===
        Section text
        ---
        ***
        ___
        _ _ _

        A line | with a pipe
        | Name | Value |
        | :--- | ---: |
        | One | *Two* |
        | [Link](https://example.com) | **Unfinished |
        | Three | Four |

        - first
          - nested **item**
        - second
        After the list
        ```swift
        let x = 1 // comment
        ```
        ~~~mermaid
        flowchart LR
        A-->B
        ~~~
        Windows\r\nline\u{2028}separator
        Emoji 👩🏽‍💻 and **unfinished
        """ + "\n\n  ````swift\n"
        + (1...48).map { "  let café\($0) = \"👩🏽‍💻\"" }.joined(separator: "\n")
        + "\n  ```\n  ````\nAfter"

    private static func outline(_ blocks: [RenderedMarkdownBlock]) -> [String] {
        blocks.map { block in
            let kind = switch block.content {
            case .heading(let level, _): "h\(level)"
            case .bulletList(let items): "list \(items.map(\.level))"
            case .paragraph: "p"
            case .quote: "quote"
            case .images, .codeBlock, .mermaid, .htmlVisual, .table: "other"
            }
            return "\(kind): " + block.inlines.map { String($0.characters) }.joined(separator: " | ")
        }
    }

    private struct BlockShape: Equatable {
        let kind: String
        let inlines: [AttributedString]
    }

    private static func shape(_ blocks: [RenderedMarkdownBlock]) -> [BlockShape] {
        blocks.map { block in
            let kind = switch block.content {
            case .heading(let level, _): "heading \(level)"
            case .bulletList(let items): "list \(items.map(\.level))"
            case .codeBlock(let language, let code, _): "code \(language ?? "") \(code)"
            case .mermaid(let source, let isComplete): "mermaid \(isComplete) \(source)"
            case .table(let headers, let alignments, let rows, let counts):
                "table \(headers.count) \(alignments) \(rows.map(\.count)) \(counts)"
            case .htmlVisual(let url, let title): "visual \(url) \(title)"
            case .images(let images): "images \(images.map(\.url))"
            case .paragraph: "paragraph"
            case .quote: "quote"
            }
            return BlockShape(kind: kind, inlines: block.inlines)
        }
    }
}

extension RenderedMarkdownBlock {
    var inlines: [AttributedString] {
        switch content {
        case .heading(_, let content), .paragraph(let content), .quote(let content): [content]
        case .codeBlock(_, _, let presentation): [presentation.content]
        case .images, .mermaid, .htmlVisual: []
        case .bulletList(let items): items.map(\.content)
        case .table(let headers, _, let rows, _): headers + rows.flatMap { $0 }
        }
    }
}

private struct RevealOracleMark: TextAttribute {
    let id: Int
}
