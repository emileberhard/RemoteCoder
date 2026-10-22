#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

@MainActor
protocol ComposerNativeTextEditor: AnyObject {
    var composerSelection: NSRange { get set }
    var isComposing: Bool { get }
    var isEditable: Bool { get set }
    var composerFontSize: CGFloat { get }
    var composerAttributes: [NSAttributedString.Key: Any] { get }
    var composerTheme: AppThemeStore { get }
    func replaceComposerCharacters(in range: NSRange, with text: NSAttributedString, resetsUndo: Bool)
    func finishComposition()
}

@MainActor
final class ComposerEditorSession {
    let document: ComposerDocument
    let graph: ComposerTextGraph
    private weak var editor: (any ComposerNativeTextEditor)?
    private var token: UUID?
    private var pendingTypography = false
    private var preparedFontSize: CGFloat?

    init(document: ComposerDocument, theme: AppThemeStore, fontSize: CGFloat) {
        self.document = document
        graph = ComposerTextGraph(document: document, theme: theme, fontSize: fontSize)
    }

    func connect(_ editor: any ComposerNativeTextEditor) {
        self.editor = editor
        token = document.mount(graph.storage, editor: { [weak self] request in
            guard let self else { request.complete(.failure(CancellationError())); return }
            perform(request)
        }, isComposing: { [weak editor] in editor?.isComposing == true }, onRetire: { [weak editor] in
            editor?.finishComposition()
            editor?.isEditable = false
        })
        let length = graph.storage.length
        let location = min(document.selection.location, length)
        editor.composerSelection = NSRange(location: location, length: min(document.selection.length, length - location))
        prepareAttachments()
    }

    func disconnect() {
        editor?.finishComposition()
        document.editorStateChanged()
        if let token { document.unmount(token) }
        token = nil
        editor = nil
    }

    func activate() {
        guard let token, let editor else { return }
        document.activate(token, selection: editor.composerSelection)
    }

    func prepareAttachments() {
        guard let editor else { return }
        guard preparedFontSize != editor.composerFontSize else { return }
        guard !document.isComposing else { pendingTypography = true; return }
        pendingTypography = false
        let storage = graph.storage
        storage.beginEditing()
        storage.addAttributes(editor.composerAttributes, range: NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(ComposerDocument.pastedTextKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let entry = (value as? any PastedTextReferencing)?.pastedText else { return }
            if let existing = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? InlinePastedTextAttachment,
               existing.fontSize == editor.composerFontSize { return }
            storage.addAttribute(.attachment, value: InlinePastedTextAttachment(entry: entry, title: InlineMessageContent.title(for: entry.text),
                fontSize: editor.composerFontSize, theme: editor.composerTheme), range: range)
        }
        storage.endEditing()
        preparedFontSize = editor.composerFontSize
    }

    func flushPending() {
        document.editorStateChanged()
        if pendingTypography { prepareAttachments() }
    }

    private func perform(_ request: ComposerDocument.Request) {
        guard let editor else { request.complete(.failure(CancellationError())); return }
        guard let (range, content) = document.replacement(for: request.edit) else {
            request.complete(.success(()))
            return
        }
        let text = inlinePastedText(content, titles: [:], attributes: editor.composerAttributes,
            fontSize: editor.composerFontSize, theme: editor.composerTheme)
        let resetsUndo: Bool
        if case .replaceAll = request.edit { resetsUndo = true } else { resetsUndo = false }
        editor.replaceComposerCharacters(in: range, with: text, resetsUndo: resetsUndo)
        activate()
        request.complete(.success(()))
    }
}
