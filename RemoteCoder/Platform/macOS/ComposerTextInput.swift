#if os(macOS)
import AppKit
import SwiftUI

struct ComposerTextInput: View {
    let document: ComposerDocument
    let prompt: String
    let focus: ComposerFocus
    let actions: ComposerInputActions
    let maximumLines: Int

    var body: some View {
        ComposerTextView(document: document, prompt: prompt, actions: actions, maximumLines: maximumLines)
            .focused(focus)
            .focusEffectDisabled()
            .overlay(alignment: .topLeading) {
                if document.isEmpty {
                    Text(prompt)
                        .scaledFont(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension ComposerTextInput {
    static func takeFocus(in window: NSWindow) {
        guard let textView = window.contentView.flatMap(composerTextView(in:)), textView.isEditable,
              !textView.isHiddenOrHasHiddenAncestor else { return }
        _ = window.makeFirstResponder(textView)
    }

    private static func composerTextView(in view: NSView) -> ComposerNSTextView? {
        if let textView = view as? ComposerNSTextView { return textView }
        for subview in view.subviews {
            if let textView = composerTextView(in: subview) { return textView }
        }
        return nil
    }
}

typealias ComposerFocus = FocusState<Bool>.Binding

extension FocusState.Binding where Value == Bool {
    @MainActor func dismissSoftwareKeyboard() {}
}

private struct ComposerTextView: NSViewRepresentable {
    @Environment(AppThemeStore.self) private var theme
    @Environment(\.interfaceScale) private var scale
    let document: ComposerDocument
    let prompt: String
    let actions: ComposerInputActions
    let maximumLines: Int

    func makeCoordinator() -> ComposerTextCoordinator {
        ComposerTextCoordinator(document: document, actions: actions, theme: theme, scale: scale)
    }

    func makeNSView(context: Context) -> ComposerScrollView {
        let view = ComposerScrollView(coordinator: context.coordinator, scale: context.environment.interfaceScale, theme: theme)
        context.coordinator.session.connect(view.textView)
        return view
    }

    func updateNSView(_ view: ComposerScrollView, context: Context) {
        context.coordinator.actions = actions
        view.apply(scale: context.environment.interfaceScale)
        view.textView.isEditable = context.environment.isEnabled && !document.isRetired
        view.textView.setAccessibilityPlaceholderValue(prompt)
    }

    static func dismantleNSView(_ view: ComposerScrollView, coordinator: ComposerTextCoordinator) {
        coordinator.session.disconnect()
        view.textView.isEditable = false
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ComposerScrollView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? ComposerScrollView.idealWidth
        return CGSize(width: width, height: view.fittingHeight(forWidth: width, maximumLines: maximumLines))
    }
}

@MainActor
private final class ComposerTextCoordinator: NSObject, NSTextViewDelegate {
    let session: ComposerEditorSession
    var actions: ComposerInputActions

    init(document: ComposerDocument, actions: ComposerInputActions, theme: AppThemeStore, scale: CGFloat) {
        session = ComposerEditorSession(document: document, theme: theme, fontSize: NSFont.preferredFont(forTextStyle: .body).pointSize * scale)
        self.actions = actions
    }

    func undoManager(for view: NSTextView) -> UndoManager? { session.document.undoManager }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if textView.window?.firstResponder === textView { session.activate() }
        session.flushPending()
        textView.enclosingScrollView?.invalidateIntrinsicContentSize()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, view.window?.firstResponder === view else { return }
        session.activate()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.isDisjoint(with: [.shift, .option]) == false {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                actions.send()
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard session.document.isEmpty, let prompt = actions.lastSentPrompt() else { return false }
            session.document.edit(.insert(prompt))
            return true
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            return TranscriptScrollHalt.forward(.pageUp, from: textView)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            return TranscriptScrollHalt.forward(.pageDown, from: textView)
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            return TranscriptScrollHalt.forward(.beginning, from: textView)
        case #selector(NSResponder.scrollToEndOfDocument(_:)):
            return TranscriptScrollHalt.forward(.end, from: textView)
        case #selector(NSResponder.cancelOperation(_:)):
            if !actions.stop() {
                textView.nextResponder?.tryToPerform(selector, with: textView)
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            textView.window?.selectKeyView(following: textView)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            textView.window?.selectKeyView(preceding: textView)
            return true
        default:
            return false
        }
    }

    func paste(into textView: ComposerNSTextView, sender: Any?) {
        let paste = Pasteboard.composerPaste(from: .general)
        if paste.hasAttachments { actions.attach(paste) }
        if let text = paste.inlineText { textView.insertText(text, replacementRange: textView.selectedRange()) }
    }

    func dropTargetChanged(_ isTargeted: Bool) {
        actions.dropTargetChanged(isTargeted)
    }

    func drop(from pasteboard: NSPasteboard) {
        actions.attach(Pasteboard.composerDrop(from: pasteboard))
    }
}

private final class ComposerNSTextView: NSTextView, ComposerNativeTextEditor, InlinePastedTextOpening {
    let composerTheme: AppThemeStore
    private let composerGraph: ComposerTextGraph
    private weak var document: ComposerDocument?

    init(graph: ComposerTextGraph, document: ComposerDocument, theme: AppThemeStore) {
        composerTheme = theme
        composerGraph = graph
        self.document = document
        super.init(frame: .zero, textContainer: graph.container)
        register([.onScrollingOutOfViewport, .onEditingInlineParagraphs], forTextAttachmentViewProviderType: InlinePastedTextViewProvider.self)
    }

    required init?(coder: NSCoder) { nil }

    override var undoManager: UndoManager? { document?.undoManager ?? super.undoManager }

    var composerSelection: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }
    var isComposing: Bool { hasMarkedText() }
    var composerFontSize: CGFloat { font?.pointSize ?? NSFont.preferredFont(forTextStyle: .body).pointSize }
    var composerAttributes: [NSAttributedString.Key: Any] { typingAttributes }

    func replaceComposerCharacters(in range: NSRange, with text: NSAttributedString, resetsUndo: Bool) {
        breakUndoCoalescing()
        insertText(text, replacementRange: range)
        breakUndoCoalescing()
        if resetsUndo { undoManager?.removeAllActions() }
        enclosingScrollView?.invalidateIntrinsicContentSize()
    }

    func finishComposition() { unmarkText() }

    func openPastedText(_ id: UUID) { composer?.actions.openPastedText(id) }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { composer?.session.activate() }
        return accepted
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if insertString is String { clearPasteTypingAttributes() }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        clearPasteTypingAttributes()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        super.unmarkText()
        Task { @MainActor [weak self] in self?.composer?.session.flushPending() }
    }

    private func clearPasteTypingAttributes() {
        var attributes = typingAttributes
        attributes.removeValue(forKey: .attachment)
        attributes.removeValue(forKey: ComposerDocument.pastedTextKey)
        typingAttributes = attributes
    }

    override func copy(_ sender: Any?) {
        guard let document = composer?.session.document else { return }
        let text = document.content(in: selectedRange()).expandedText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard isEditable else { return }
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }

    weak var composer: ComposerTextCoordinator?
    private var isDropTargeted = false

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, composer != nil, Pasteboard.carriesAttachments(.general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        guard let composer else { return super.paste(sender) }
        composer.paste(into: self, sender: sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
    }

    override func dragOperation(for dragInfo: any NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        guard isEditable, Pasteboard.carriesAttachments(dragInfo.draggingPasteboard) else {
            return super.dragOperation(for: dragInfo, type: type)
        }
        setDropTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setDropTargeted(false)
        super.draggingExited(sender)
    }

    override func cleanUpAfterDragOperation() {
        setDropTargeted(false)
        super.cleanUpAfterDragOperation()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let composer, isEditable, Pasteboard.carriesAttachments(sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        setDropTargeted(false)
        let position = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: position, length: 0))
        composer.session.activate()
        composer.drop(from: sender.draggingPasteboard)
        return true
    }

    private func setDropTargeted(_ isTargeted: Bool) {
        guard isDropTargeted != isTargeted else { return }
        isDropTargeted = isTargeted
        composer?.dropTargetChanged(isTargeted)
    }
}

private final class ComposerScrollView: NSScrollView {
    static let idealWidth: CGFloat = 320
    let textView: ComposerNSTextView
    private var scale: CGFloat
    private var lineHeight: CGFloat = 0

    init(coordinator: ComposerTextCoordinator, scale: CGFloat, theme: AppThemeStore) {
        textView = ComposerNSTextView(graph: coordinator.session.graph, document: coordinator.session.document, theme: theme)
        self.scale = scale
        super.init(frame: .zero)
        textView.composer = coordinator
        textView.delegate = coordinator
        applyTypography()
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.writingToolsBehavior = .none
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityIdentifier("codex-composer-input")
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        documentView = textView
    }

    required init?(coder: NSCoder) { nil }

    func apply(scale: CGFloat) {
        guard scale != self.scale else { return }
        self.scale = scale
        applyTypography()
        textView.composer?.session.prepareAttachments()
        invalidateIntrinsicContentSize()
    }

    private func applyTypography() {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let font = body.withSize(body.pointSize * scale)
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        textView.font = font
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes([.font: font, .paragraphStyle: paragraph],
                                  range: NSRange(location: 0, length: storage.length))
        }
    }

    func fittingHeight(forWidth width: CGFloat, maximumLines: Int) -> CGFloat {
        let cap = lineHeight * CGFloat(maximumLines)
        let height = if abs(textView.frame.width - width) <= 0.5, let layout = textView.textLayoutManager {
            Self.usedHeight(of: layout, upTo: cap)
        } else {
            measuredHeight(forWidth: width, upTo: cap)
        }
        return min(max(ceil(height), lineHeight), cap)
    }

    private func measuredHeight(forWidth width: CGFloat, upTo cap: CGFloat) -> CGFloat {
        let content = NSTextContentStorage()
        content.attributedString = NSAttributedString(attributedString: textView.attributedString())
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: 0))
        container.lineFragmentPadding = textView.textContainer?.lineFragmentPadding ?? 0
        layout.textContainer = container
        content.addTextLayoutManager(layout)
        return Self.usedHeight(of: layout, upTo: cap)
    }

    private static func usedHeight(of layout: NSTextLayoutManager, upTo cap: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            height = fragment.layoutFragmentFrame.maxY
            return height < cap
        }
        return height
    }
}
#endif
