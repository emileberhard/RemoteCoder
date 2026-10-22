import Foundation
import Testing
@testable import RemoteCoderCore

struct ComposerPasteTests {
    @Test func fileURLsWinWithoutReadingImagesOrText() {
        var reads = 0
        func images() -> [Int] { reads += 1; return [1] }
        func string() -> String? { reads += 1; return "caption" }
        let urls = [URL(fileURLWithPath: "/tmp/report.pdf"), URL(fileURLWithPath: "/tmp/folder", isDirectory: true)]

        let paste = ComposerPaste(fileURLs: urls, images: images(), string: string())

        #expect(paste.fileURLs == urls)
        #expect(paste.images.isEmpty)
        #expect(paste.text == nil)
        #expect(paste.hasAttachments)
        #expect(reads == 0)
    }

    @Test func textIsPromotedAtFifteenHundredTrimmedCharacters() {
        let belowThreshold = String(repeating: "a", count: 1_499)
        let atThreshold = String(repeating: "a", count: 1_500)

        let rawInline = "  \n\(belowThreshold)\n  "
        let rawAttachment = atThreshold + "\n"
        let inline = ComposerPaste<Int>(fileURLs: [], images: [], string: rawInline)
        let promoted = ComposerPaste<Int>(fileURLs: [], images: [], string: rawAttachment)

        #expect(inline.text == .inline(rawInline))
        #expect(inline.inlineText == rawInline)
        #expect(!inline.hasAttachments)
        #expect(promoted.text == .attachment(rawAttachment))
        #expect(promoted.inlineText == nil)
        #expect(promoted.hasAttachments)
    }

    @Test func indentationAndDictationSpacesRemainExact() {
        for raw in ["    return x\n", " dictation with spaces ", "\tfirst\r\n\tsecond\n"] {
            #expect(ComposerPastedText(raw) == .inline(raw))
        }
        let raw = "\n    " + String(repeating: "indented code\n    ", count: 100) + "\n"
        #expect(ComposerPastedText(raw) == .attachment(raw))
    }

    @Test func imagesKeepShortTextInline() {
        let paste = ComposerPaste(fileURLs: [], images: [7, 8], string: "Look at these")

        #expect(paste.images == [7, 8])
        #expect(paste.inlineText == "Look at these")
        #expect(paste.hasAttachments)
    }

    @Test func whitespaceOnlyTextPastesNothing() {
        let paste = ComposerPaste<Int>(fileURLs: [], images: [], string: " \n\t ")

        #expect(paste.text == nil)
        #expect(paste.inlineText == nil)
        #expect(!paste.hasAttachments)
    }
}
