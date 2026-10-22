import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ComposerDocumentTests {
    @Test(arguments: ["", " \n\t "])
    func blankPastesRemainPlainTextAcrossPersistenceAndCannotEnableSending(_ whitespace: String) throws {
        let standalone = ComposerDocumentContent(runs: [.paste(.init(id: UUID(), text: whitespace))])
        #expect(try JSONDecoder().decode(ComposerDocumentContent.self, from: JSONEncoder().encode(standalone)) == standalone)
        #expect(standalone.expandedText == whitespace)
        #expect(standalone.pasted.isEmpty)
        #expect(standalone.runs.isEmpty == whitespace.isEmpty)
        let content = ComposerDocumentContent(runs: [.text(" "), .paste(.init(id: UUID(), text: whitespace))])
        let encoded = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(ComposerDocumentContent.self, from: encoded)
        let document = ComposerDocument(content: decoded, onChange: {})
        #expect(document.content.expandedText == " " + whitespace)
        #expect(document.content.pasted.isEmpty)
        #expect(!document.hasContent)
        #expect(document.controlText.isEmpty)
        let useful = PastedTextPromptBlock.Entry(id: UUID(), text: "  useful content\n")
        document.edit(.append(.init(runs: [.paste(useful)])))
        #expect(document.hasContent)
        #expect(document.content.pasted == [useful])
        #expect(document.content.expandedText == " " + whitespace + useful.text)
    }

    @Test func boundedControlsKeepSlashMeaningAfterLeadingWhitespaceAndRangeEdits() {
        let spaces = String(repeating: " ", count: 10_000)
        let document = ComposerDocument(content: .init(runs: [.text(spaces + "/compact")]), onChange: {})
        #expect(document.controlText == "/compact")
        document.edit(.replace(NSRange(location: 10_000, length: 8), .init(runs: [.text("hello")])))
        #expect(document.controlText == "hello")
        document.edit(.replace(NSRange(location: 0, length: 10_000), .init(runs: [])))
        #expect(document.controlText == "hello")
        document.edit(.replace(NSRange(location: 0, length: 5), .init(runs: [])))
        #expect(document.controlText.isEmpty)
        document.edit(.insert(.init(runs: [.text("  restored")])) )
        #expect(document.controlText == "restored")
        document.edit(.replaceAll(.init(runs: [.text(spaces + "/compact" + spaces)])))
        #expect(ComposerSlashCommand.parse(document.controlText) == .command(.compact))
        document.edit(.append(.init(runs: [.text("argument")])))
        #expect(ComposerSlashCommand.parse(document.controlText) == .unexpectedArguments(.compact))
    }

    @Test func rangeEditsPreserveChipIdentityAndDictationOrder() throws {
        let id = UUID()
        let document = ComposerDocument(content: .init(runs: [.text("one four")]), onChange: {})
        document.selection = NSRange(location: 4, length: 0)
        document.edit(.insert(.init(runs: [.paste(.init(id: id, text: "two")), .text(" three ")])))
        #expect(document.content.expandedText == "one two three four")
        #expect(document.content.pasted.first?.id == id)
        document.edit(.updatePaste(id, "updated two"))
        #expect(document.content.expandedText == "one updated two three four")
        #expect(document.content.pasted.first?.id == id)
        document.edit(.replace(NSRange(location: 4, length: 1), .init(runs: [])))
        #expect(document.content.expandedText == "one  three four")
        document.edit(.updatePaste(id, "late edit"))
        #expect(document.content.pasted.isEmpty)
    }

    @Test func persistedDocumentKeepsInlineOrderAndMediaSeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "inline-draft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChatFixture))
        store.setText("before after", in: draft)
        let document = store.document(for: draft)
        document.selection = NSRange(location: 7, length: 0)
        let paste = ComposerAttachment.text("pasted content")
        store.setAttachments([paste], in: draft)
        store.appendText("dictation", to: draft)
        #expect(await store.flush())
        let reopened = ComposerDraftStore(directory: directory)
        let restored = try #require(await reopened.draft(for: .newChatFixture))
        #expect(reopened.document(for: restored).content.expandedText == "before pasted content dictation after")
        #expect(reopened.document(for: restored).content.pasted.first?.id == paste.id)
        #expect(restored.attachments.isEmpty)
        #expect(restored.text == "before pasted content dictation after")
    }

    @Test func markedInputDefersEditsAcrossSharedEditorsAndCancellationRemovesOnlyItsRequest() async throws {
        let document = ComposerDocument(content: .init(runs: [.text("before")]), onChange: {})
        let storage = NSMutableAttributedString(attributedString: document.buffer)
        var composing = true
        var applied: [ComposerDocument.Edit] = []
        let first = try #require(document.mount(storage, editor: { request in
            applied.append(request.edit)
            request.complete(.success(()))
        }, isComposing: { composing }, onRetire: {}))
        let second = try #require(document.mount(storage, editor: { request in
            applied.append(request.edit)
            request.complete(.success(()))
        }, isComposing: { false }, onRetire: {}))
        document.activate(second, selection: NSRange(location: 6, length: 0))
        document.edit(.insert(.init(runs: [.paste(.init(id: UUID(), text: "pending paste"))])))
        #expect(applied.isEmpty)
        #expect(document.buffer === storage)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let canceled = Task { @MainActor in
            continuation.yield(())
            try await document.apply(.dictation("canceled dictation"))
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        canceled.cancel()
        do { try await canceled.value; Issue.record("Canceled deferred edit completed") }
        catch is CancellationError {}
        composing = false
        document.editorStateChanged()
        #expect(applied.count == 1)
        if case .insert(let content) = applied.first { #expect(content.pasted.first?.text == "pending paste") }
        else { Issue.record("The surviving paste was replaced") }
        document.unmount(second)
        document.unmount(first)
        #expect(document.buffer !== storage)
    }
}
