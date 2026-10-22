import Foundation
import Testing
@testable import RemoteCoderCore

struct RenderedInlineMessageTests {
    @Test func typedRunsKeepMarkdownStylesAndPasteIdentity() throws {
        let entry = PastedTextPromptBlock.Entry(id: UUID(), text: "**literal pasted content**\n    code")
        let source = InlineMessageContent(.init(runs: [
            .text("**bold** and *italic* "), .paste(entry),
            .text(" `let x = 1` [site](https://example.com)\nnext line"),
        ]))
        let rendered = RenderedInlineMessage(source)
        #expect(rendered.runs.count == 3)
        guard case .text(let before) = rendered.runs[0], case .paste(let paste) = rendered.runs[1],
              case .text(let after) = rendered.runs[2] else {
            Issue.record("Typed text and the paste must keep their composed order")
            return
        }
        #expect(String(before.characters) == "bold and italic ")
        #expect(String(after.characters) == " let x = 1 site\nnext line")
        let bold = try #require(before.range(of: "bold"))
        let italic = try #require(before.range(of: "italic"))
        let code = try #require(after.range(of: "let x = 1"))
        let link = try #require(after.range(of: "site"))
        #expect(before[bold].inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(before[italic].inlinePresentationIntent?.contains(.emphasized) == true)
        #expect(after[code].inlinePresentationIntent?.contains(.code) == true)
        #expect(after[link].link == URL(string: "https://example.com"))
        #expect(paste == entry)
        #expect(rendered.plainText == "bold and italic **literal pasted content**\n    code let x = 1 site\nnext line")
        #expect(rendered.source.plainText == "**bold** and *italic* **literal pasted content**\n    code `let x = 1` [site](https://example.com)\nnext line")
    }
}
