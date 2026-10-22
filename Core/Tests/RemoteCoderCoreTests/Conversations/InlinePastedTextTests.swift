import Foundation
import Testing
@testable import RemoteCoderCore

struct InlinePastedTextTests {
    @Test func literalSearchPreservesOverlappingCandidatesAndRestrictedRanges() {
        for text in ["aba", "ababa", "aba\u{301}", "界 ababa 🧑‍💻 aba a", "e\u{301} ab"] {
            for backwards in [false, true] {
                let options: String.CompareOptions = backwards ? [.literal, .backwards] : [.literal]
                for bounds in [text.startIndex..<text.endIndex, text.startIndex..<text.index(before: text.endIndex),
                               text.index(after: text.startIndex)..<text.endIndex] {
                    #expect(PromptMarkerSearch.range(of: "aba", in: text, range: bounds, backwards: backwards)
                            == text.range(of: "aba", options: options, range: bounds))
                }
            }
        }
    }

    @Test func unicodeAndForeignStringsKeepMarkerBoundariesAndInlineOrder() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        for prefix in ["é 👩🏽‍💻 中文\n", "e\u{301} <remotecoder_\u{301} invalid ", String(repeating: "🧑‍💻 <remote ", count: 1_000)] {
            let document = ComposerDocumentContent(runs: [.text(prefix), .paste(.init(id: id, text: "界 e\u{301}\n👩🏽‍💻")), .text(" fin")])
            let prompt = document.prompt
            for input in [prompt, NSString(string: prompt) as String] {
                #expect(InlinePastedText.parse(input) == document)
                let withFile = AttachedFilesPromptBlock.append(to: input, paths: ["/host/界.txt"])
                let prepared = UserMessageText(withFile)
                #expect(prepared.inline == document)
                #expect(prepared.filePaths == ["/host/界.txt"])
            }
        }
    }

    @Test func trailingFileMarkerSearchKeepsTheLastCandidateAndRejectsIncompleteHeaders() {
        let header = AttachedFilesPromptBlock.render([])
        let body = "界\n\n\(header)\n- /typed.txt\n\ncaption 👩🏽‍💻"
        let prompt = AttachedFilesPromptBlock.append(to: body, paths: ["/host/real.txt"])
        #expect(AttachedFilesPromptBlock.parse(prompt)?.body == body)
        #expect(AttachedFilesPromptBlock.parse(prompt)?.paths == ["/host/real.txt"])
        #expect(AttachedFilesPromptBlock.parse(prompt + "\n\n" + header) == nil)
        #expect(AttachedFilesPromptBlock.parse(prompt + "\n\n" + header + "\ninvalid") == nil)
    }

    @Test func persistedRunsRejectDuplicateOrEmptyPastesAndTransfersKeepDistinctIdentity() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        for entries in [[PastedTextPromptBlock.Entry(id: id, text: " ")], [.init(id: id, text: "one"), .init(id: id, text: "two")]] {
            let data = try JSONEncoder().encode(["runs": entries.map { ComposerDocumentContent.Run.paste($0) }])
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ComposerDocumentContent.self, from: data) }
        }
        let content = ComposerDocumentContent(runs: [.text("before "), .paste(.init(id: id, text: "paste")), .text(" after")])
        #expect(content.avoidingPasteIDs([]) == content)
        let transferred = content.avoidingPasteIDs([id])
        #expect(transferred.expandedText == content.expandedText)
        #expect(transferred.pasted.first?.id != id)
    }

    @Test func frozenPromptsPreserveOrderAndRejectMalformedMarkers() throws {
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: ProtocolFixtures.data(at: "attachments/pasted-text-v2-cases.json"))
        for fixture in fixtures {
            let parsed = InlinePastedText.parse(fixture.prompt)
            if fixture.entries.isEmpty && fixture.literal != true {
                #expect(parsed == nil, "\(fixture.name)")
                #expect(UserMessageText(fixture.prompt).body == fixture.prompt, "\(fixture.name)")
            } else {
                let document = try #require(parsed, "\(fixture.name)")
                #expect(document.expandedText == fixture.expanded, "\(fixture.name)")
                #expect(document.summary == fixture.summary, "\(fixture.name)")
                #expect(document.pasted == fixture.entries, "\(fixture.name)")
                #expect(InlinePastedText.parse(document.prompt) == document, "\(fixture.name)")
            }
            let original = fixture.runs.map { ComposerDocumentContent(runs: $0) }
                ?? parsed ?? ComposerDocumentContent(runs: [.text(fixture.prompt)])
            if fixture.runs != nil { #expect(original.prompt == fixture.prompt, "\(fixture.name)") }
            let presented = UserMessageText(original.prompt)
            let restored = presented.inline ?? ComposerDocumentContent(runs: [.text(presented.body)])
            #expect(restored == original, "\(fixture.name)")
            #expect(presented.pasted == original.pasted, "\(fixture.name)")
        }
    }

    private struct Fixture: Decodable {
        let name: String
        let prompt: String
        let expanded: String
        let summary: String
        let entries: [PastedTextPromptBlock.Entry]
        let literal: Bool?
        let runs: [ComposerDocumentContent.Run]?
    }
}
