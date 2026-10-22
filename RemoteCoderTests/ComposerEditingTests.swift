import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@MainActor
@Suite(.serialized)
struct ComposerEditingTests {
    @Test func plainRepresentableDocumentsFrameworkRetention() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let graph = try await releaseControlGraph(scene: scene)
        let released = await waitUntil(timeout: .seconds(5)) { graph.isReleased }
        FileHandle.standardError.write(Data("UIKit baseline text graph released: \(released)\n".utf8))
    }

    private func releaseControlGraph(scene: UIWindowScene) async throws -> WeakGraph {
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: AnyView(PlainTextControl()))
        hosted.show(controller)
        defer { hosted.close() }
        let graph = try await captureControlGraph(controller)
        unmount(controller, from: hosted)
        return graph
    }

    private func captureControlGraph(_ controller: UIHostingController<AnyView>) async throws -> WeakGraph {
        for _ in 0..<20 {
            await layout(controller.view)
            if let view = findTextView(controller.view) {
                #expect(view.becomeFirstResponder())
                view.insertText("plain edit")
                return WeakGraph(view: view, manager: try #require(view.textLayoutManager),
                    content: try #require(view.textLayoutManager?.textContentManager as? NSTextContentStorage))
            }
        }
        throw CocoaError(.coderInvalidValue)
    }

    @Test func unmountReleasesComposerOwnershipAndClearsUndoTargets() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let owners = try await releaseComposerOwnership(scene: scene)
        #expect(await waitUntil(timeout: .seconds(5)) { owners.isReleased })
    }

    @Test func repeatedDraftMountsKeepUIKitRetentionBounded() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var owners: [WeakOwnership] = []
        for _ in 0..<10 {
            owners.append(try await releaseComposerOwnership(scene: scene))
        }
        let bounded = await waitUntil(timeout: .seconds(5)) {
            owners.allSatisfy { $0.isReleased } && owners.count(where: { $0.view != nil }) <= 1
        }
        let views = owners.count(where: { $0.view != nil })
        FileHandle.standardError.write(Data("UIKit repeated mounts: \(views) of 10 native views retained\n".utf8))
        let allReleased = owners.allSatisfy { $0.isReleased }
        #expect(bounded)
        #expect(allReleased)
        #expect(views <= 1)
    }

    private func releaseComposerOwnership(scene: UIWindowScene) async throws -> WeakOwnership {
        let document = ComposerDocument(content: .init(runs: [.text("before "), .paste(.init(id: UUID(), text: "paste")), .text(" after")]), onChange: {})
        let owners = try await releaseComposerGraph(scene: scene, document: document)
        #expect(await waitUntil(timeout: .seconds(5)) {
            !(document.buffer is NSTextStorage) && !document.undoManager.canUndo
        })
        return owners
    }

    private func releaseComposerGraph(scene: UIWindowScene, document: ComposerDocument) async throws -> WeakOwnership {
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: AnyView(ComposerFixture(document: document).environment(AppThemeStore())))
        hosted.show(controller)
        defer { hosted.close() }
        let owners = try await captureMountedOwnership(controller: controller, document: document)
        #expect(document.undoManager.canUndo)
        unmount(controller, from: hosted)
        return owners
    }

    private func unmount(_ controller: UIHostingController<AnyView>, from hosted: HostedWindow) {
        autoreleasepool {
            findTextView(controller.view)?.resignFirstResponder()
            controller.rootView = AnyView(EmptyView())
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            controller.view.removeFromSuperview()
            hosted.close()
        }
    }

    private func captureMountedOwnership(controller: UIHostingController<AnyView>, document: ComposerDocument) async throws -> WeakOwnership {
        for _ in 0..<20 {
            await layout(controller.view)
            if let view = findTextView(controller.view) {
                #expect(view.becomeFirstResponder())
                view.selectedRange = NSRange(location: 8, length: 0)
                let id = try #require(document.content.pasted.first?.id)
                document.edit(.updatePaste(id, "edited"))
                let reference = try #require(Mirror(reflecting: view).children.first { $0.label == "composer" })
                let coordinator = try #require(Mirror(reflecting: reference.value).children.first?.value as AnyObject?)
                let undoTarget = NSObject()
                document.undoManager.registerUndo(withTarget: undoTarget) { _ in }
                return WeakOwnership(view: view, document: document, coordinator: coordinator, undoTarget: undoTarget)
            }
        }
        throw CocoaError(.coderInvalidValue)
    }

    private final class WeakOwnership {
        weak var view: UITextView?
        weak var document: ComposerDocument?
        weak var coordinator: AnyObject?
        weak var undoTarget: NSObject?
        init(view: UITextView, document: ComposerDocument, coordinator: AnyObject, undoTarget: NSObject) {
            self.view = view
            self.document = document
            self.coordinator = coordinator
            self.undoTarget = undoTarget
        }
        var isReleased: Bool { document == nil && coordinator == nil && undoTarget == nil }
    }

    @Test func attachmentProviderAndItsButtonDoNotRetainTheAttachment() async throws {
        let references = try releaseProvider()
        #expect(await waitUntil(timeout: .seconds(5)) { references.allSatisfy { $0.value == nil } })
    }

    private func releaseProvider() throws -> [WeakObject] {
        try autoreleasepool {
            let content = NSTextContentStorage()
            content.textStorage = NSTextStorage(string: "\u{FFFC}")
            let attachment = InlinePastedTextAttachment(entry: .init(id: UUID(), text: "pasted body"), title: "paste", fontSize: 17, theme: AppThemeStore())
            let provider = try #require(attachment.viewProvider(for: nil, location: content.documentRange.location, textContainer: nil))
            provider.loadView()
            return [WeakObject(attachment), WeakObject(provider)]
        }
    }

    private final class WeakObject {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    private final class WeakGraph {
        weak var view: UITextView?
        weak var manager: NSTextLayoutManager?
        weak var content: NSTextContentStorage?
        init(view: UITextView, manager: NSTextLayoutManager, content: NSTextContentStorage) {
            self.view = view
            self.manager = manager
            self.content = content
        }
        var isReleased: Bool { view == nil && manager == nil && content == nil }
    }

    @Test func inlinePasteSelectionCopyDeleteAndViewerEditShareNativeUndo() async throws {
        let document = ComposerDocument(content: .init(runs: [.text("before after")]), onChange: {})
        try await withComposer(document) { view in
            view.selectedRange = NSRange(location: 7, length: 0)
            let id = UUID()
            document.edit(.insert(.init(runs: [.paste(.init(id: id, text: "full pasted content"))])))
            await layout(view)
            #expect(document.buffer === view.textStorage)
            #expect(view.text == "before \u{FFFC}after")
            #expect(document.content.expandedText == "before full pasted contentafter")
            document.edit(.updatePaste(id, "edited pasted content"))
            await layout(view)
            #expect(document.content.pasted.first?.text == "edited pasted content")
            view.undoManager?.undo()
            await layout(view)
            #expect(document.content.pasted.first == .init(id: id, text: "full pasted content"))
            view.undoManager?.redo()
            await layout(view)
            #expect(document.content.pasted.first == .init(id: id, text: "edited pasted content"))
            let clipboard = UIPasteboard.general.items
            defer { UIPasteboard.general.items = clipboard }
            view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
            view.copy(nil)
            #expect(UIPasteboard.general.string == "before edited pasted contentafter")
            view.selectedRange = NSRange(location: 8, length: 0)
            view.deleteBackward()
            await layout(view)
            #expect(document.content.pasted.isEmpty)
            #expect(view.text == "before after")
            view.undoManager?.undo()
            await layout(view)
            #expect(document.content.pasted.first == .init(id: id, text: "edited pasted content"))
            view.selectedRange = NSRange(location: 8, length: 0)
            view.insertText(" typed ")
            await layout(view)
            #expect(document.content.pasted.count == 1)
            #expect(document.content.expandedText == "before edited pasted content typed after")
        }
    }

    @Test func retirementDrainsMarkedInputAndDetachesLateNativeEditsBeforeSaving() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "native-retirement-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(directory: directory)
        defer { await store.retire() }
        let destination = ComposerDraftStore.Destination.newChat(UUID())
        let draft = try #require(await store.draft(for: destination))
        store.setText("before ", in: draft)
        let document = store.document(for: draft)
        try await withComposer(document) { view in
            view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
            view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
            await layout(view)
            #expect(document.isComposing)
            store.setText("Accepted before retirement", in: draft)
            #expect(document.content.expandedText != "Accepted before retirement")
            let nativeStorage = view.textStorage
            #expect(await store.retire())
            #expect(!view.isEditable)
            #expect(document.buffer !== nativeStorage)
            nativeStorage.replaceCharacters(in: NSRange(location: 0, length: nativeStorage.length), with: "Late native edit")
            view.unmarkText()
            document.edit(.replaceAll(.init(runs: [.text("Late document edit")])))
            await layout(view)
            #expect(!view.isEditable)
            #expect(document.content.expandedText == "Accepted before retirement")
        }
        let replacement = ComposerDraftStore(directory: directory)
        defer { await replacement.retire() }
        #expect(await replacement.draft(for: destination)?.document?.content.expandedText == "Accepted before retirement")
    }

    @Test func japaneseMarkedInputDefersDictationUntilCommitAndPreservesChip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "native-composer-\(UUID())")
        let store = ComposerDraftStore(directory: directory)
        let draft = try #require(await store.draft(for: .newChat(UUID())))
        let id = UUID()
        store.setContent(.init(runs: [.text("before "), .paste(.init(id: id, text: "paste")), .text(" after")]), in: draft)
        let document = store.document(for: draft)
        try await withComposer(document) { view in
            view.selectedRange = NSRange(location: 8, length: 0)
            view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
            await layout(view)
            #expect(document.isComposing)
            let recordingID = UUID()
            let (started, continuation) = AsyncStream<Void>.makeStream()
            let dictation = Task { @MainActor in
                continuation.yield(())
                try await store.appendDictation("dictated", recordingID: recordingID, to: draft)
            }
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            #expect(!document.content.expandedText.contains("dictated"))
            #expect(try await !store.hasSavedReceipt(for: recordingID))
            view.unmarkText()
            try await dictation.value
            await layout(view)
            #expect(document.content.expandedText == "before pasteにほん dictated after")
            #expect(document.content.pasted.first?.id == id)
            #expect(!document.isComposing)
            #expect(await store.flush())
            #expect(try await store.hasSavedReceipt(for: recordingID))
            view.undoManager?.undo()
            await layout(view)
            #expect(!document.content.expandedText.contains("dictated"))
            #expect(document.content.pasted.first?.id == id)
        }
    }

    @Test func sentInlineLayoutKeepsMeasuredHeightAndOpensOriginalPaste() async throws {
        let id = UUID()
        let content = InlineMessageContent(.init(runs: [.text("**before** "), .paste(.init(id: id, text: "long pasted text")),
            .text(" *after* `code` [site](https://example.com)")]))
        let message = ChatMessage(role: .user, text: "**before**  *after* `code` [site](https://example.com)",
            inlineContent: content)
        var opened: UUID?
        let rendered = await Self.renderMessage(message)
        let prepared = try #require(rendered.inline)
        let view = InlineMessageUITextView(content: prepared, theme: AppThemeStore(), open: { opened = $0 })
        view.apply(content: prepared)
        let first = view.layout.measure(width: 280)
        view.frame = CGRect(origin: .zero, size: first)
        await layout(view)
        #expect(view.layout.measure(width: 280) == first)
        _ = view.layout.measure(width: 180)
        #expect(view.layout.measure(width: 280) == first)
        #expect(view.textContainer.size.width == 280)
        #expect(first.height > 0)
        #expect(!view.isEditable)
        let text = view.textStorage.string as NSString
        let bold = text.range(of: "before")
        let italic = text.range(of: "after")
        let code = text.range(of: "code")
        let link = text.range(of: "site")
        #expect((view.textStorage.attribute(.font, at: bold.location, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect((view.textStorage.attribute(.font, at: italic.location, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        #expect((view.textStorage.attribute(.font, at: code.location, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        #expect(view.textStorage.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
        view.copy(nil)
        #expect(UIPasteboard.general.string == "before long pasted text after code site")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        var selectedText: String?
        var menuButtons: [UUID: MenuTestButtonAction] = [:]
        let controller = UIHostingController(rootView: VStack(alignment: .leading) {
            ChatBubbleMenu(message: message, rendered: rendered, onFork: nil, queuedActions: nil,
                onSelectText: { selectedText = $0 })
        }.buttonStyle(MenuTestButtonStyle { id, action in menuButtons[id] = action }))
        hosted.show(controller)
        defer { menuButtons.removeAll(); hosted.close() }
        for _ in 0..<20 {
            await layout(controller.view)
            if menuButtons.count >= 3 { break }
        }
        let actions = menuButtons.values.sorted { $0.frame.minY < $1.frame.minY }
        try #require(actions.count >= 3)
        UIPasteboard.general.string = "not copied"
        actions[0].trigger()
        #expect(UIPasteboard.general.string == "before long pasted text after code site")
        actions[1].trigger()
        #expect(UIPasteboard.general.string == "**before** long pasted text *after* `code` [site](https://example.com)")
        actions[2].trigger()
        #expect(selectedText == "before long pasted text after code site")
        view.openPastedText(id)
        #expect(opened == id)
        let updated = InlineMessageContent(.init(runs: [.text("*updated* "), .paste(.init(id: id, text: "new paste"))]))
        var changed = message
        changed.text = "*updated* "
        changed.inlineContent = updated
        let updatedRender = await Self.renderMessage(changed)
        view.apply(content: try #require(updatedRender.inline))
        #expect(ComposerDocument.content(in: view.textStorage, range: NSRange(location: 0, length: view.textStorage.length)).expandedText == "updated new paste")
        let resized = view.layout.measure(width: 280)
        #expect(resized.height > 0)
        #expect(view.layout.measure(width: 280) == resized)
    }

    @concurrent private static func renderMessage(_ message: ChatMessage) async -> RenderedMessage {
        var highlighting = SyntaxHighlightCache()
        return RenderedMessage.render(text: message.text, inline: message.inlineContent, isStreaming: message.isStreaming,
            previous: nil, highlighting: &highlighting)
    }

    private func withComposer(_ document: ComposerDocument, check: (UITextView) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: ComposerFixture(document: document).environment(AppThemeStore()))
        hosted.show(controller)
        defer { hosted.close() }
        var textView: UITextView?
        for _ in 0..<20 {
            await layout(controller.view)
            textView = findTextView(controller.view)
            if textView != nil { break }
        }
        let view = try #require(textView)
        #expect(view.textLayoutManager != nil)
        #expect(view.becomeFirstResponder())
        await layout(view)
        try await check(view)
        view.resignFirstResponder()
    }

    private func findTextView(_ view: UIView) -> UITextView? {
        if let text = view as? UITextView, text.accessibilityIdentifier == "codex-composer-input" { return text }
        return view.subviews.lazy.compactMap(findTextView).first
    }

    private func layout(_ view: UIView) async {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
    }
}

private struct MenuTestButtonAction {
    let frame: CGRect
    let trigger: @MainActor () -> Void
}

private struct MenuTestButtonStyle: PrimitiveButtonStyle {
    let record: @MainActor (UUID, MenuTestButtonAction?) -> Void

    func makeBody(configuration: Configuration) -> some View {
        CapturedButton(configuration: configuration, record: record)
    }

    private struct CapturedButton: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let record: @MainActor (UUID, MenuTestButtonAction?) -> Void
        @State private var id = UUID()

        var body: some View {
            configuration.label
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _, frame in
                    record(id, .init(frame: frame, trigger: { configuration.trigger() }))
                }
                .onDisappear { record(id, nil) }
        }
    }
}

private struct PlainTextControl: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.text = "plain text"
        view.accessibilityIdentifier = "codex-composer-input"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
    static func dismantleUIView(_ view: UITextView, coordinator: ()) { view.resignFirstResponder() }
}

private struct ComposerFixture: View {
    let document: ComposerDocument
    @State private var focus = false

    var body: some View {
        ComposerTextInput(document: document, prompt: "Message", focus: $focus,
            actions: ComposerInputActions(send: { Issue.record("Editing must not send") }, lastSentPrompt: { nil },
                stop: { false }, attach: { _ in }, openPastedText: { _ in }, dropTargetChanged: { _ in }), maximumLines: 6)
            .frame(width: 320)
            .padding()
    }
}
