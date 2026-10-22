import SwiftUI
import UIKit

struct ComposerTextInput: View {
    let document: ComposerDocument
    let prompt: String
    let focus: ComposerFocus
    let actions: ComposerInputActions
    let maximumLines: Int

    var body: some View {
        ComposerTextView(document: document, prompt: prompt, focus: focus, actions: actions, maximumLines: maximumLines)
            .overlay(alignment: .topLeading) {
                if document.isEmpty {
                    Text(prompt)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

typealias ComposerFocus = Binding<Bool>

extension Binding where Value == Bool {
    @MainActor func dismissSoftwareKeyboard() { wrappedValue = false }
}

private struct ComposerTextView: UIViewRepresentable {
    let document: ComposerDocument
    let prompt: String
    let focus: ComposerFocus
    let actions: ComposerInputActions
    let maximumLines: Int
    @Environment(AppThemeStore.self) private var theme

    func makeCoordinator() -> ComposerTextCoordinator {
        ComposerTextCoordinator(document: document, focus: focus, actions: actions, theme: theme)
    }

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView(graph: context.coordinator.session.graph, document: document, theme: theme)
        view.composer = context.coordinator
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "Message"
        view.accessibilityIdentifier = "codex-composer-input"
        context.coordinator.session.connect(view)
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        coordinator.focus = focus
        coordinator.actions = actions
        coordinator.isEnabled = context.environment.isEnabled && !document.isRetired
        view.maximumLines = maximumLines
        coordinator.session.prepareAttachments()
        coordinator.scheduleNativeSync(view)
    }

    static func dismantleUIView(_ view: ComposerUITextView, coordinator: ComposerTextCoordinator) {
        coordinator.retire()
        view.delegate = nil
        view.composer = nil
        coordinator.session.disconnect()
        Task { @MainActor in
            if view.isFirstResponder { view.resignFirstResponder() }
            view.isEditable = false
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        return CGSize(width: width, height: uiView.composerHeight(width: width))
    }
}

@MainActor
private final class ComposerTextCoordinator: NSObject, UITextViewDelegate {
    let session: ComposerEditorSession
    var focus: ComposerFocus
    var actions: ComposerInputActions
    var isEnabled = true
    var isUpdating = false
    private var isRetired = false
    private var isNativeSyncScheduled = false

    init(document: ComposerDocument, focus: ComposerFocus, actions: ComposerInputActions, theme: AppThemeStore) {
        session = ComposerEditorSession(document: document, theme: theme, fontSize: UIFont.preferredFont(forTextStyle: .body).pointSize)
        self.focus = focus
        self.actions = actions
    }

    func retire() {
        isRetired = true
    }

    func scheduleNativeSync(_ view: UITextView) {
        guard !isRetired, !isNativeSyncScheduled,
              view.isEditable != isEnabled || focus.wrappedValue != view.isFirstResponder else { return }
        isNativeSyncScheduled = true
        Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            isNativeSyncScheduled = false
            guard !isRetired, !session.document.isRetired else { return }
            if view.isEditable != isEnabled { view.isEditable = isEnabled }
            if focus.wrappedValue, !view.isFirstResponder, view.window != nil {
                if !view.becomeFirstResponder() { publishFocus(false, of: view) }
            } else if !focus.wrappedValue, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }

    private func publishFocus(_ focused: Bool, of textView: UITextView) {
        guard !isRetired else { return }
        guard !isUpdating else {
            let requested = focus.wrappedValue
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView, focus.wrappedValue == requested, !isNativeSyncScheduled else { return }
                publishFocus(textView.isFirstResponder, of: textView)
            }
            return
        }
        if focus.wrappedValue != focused { focus.wrappedValue = focused }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        session.activate()
        publishFocus(true, of: textView)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        session.flushPending()
        publishFocus(false, of: textView)
    }

    func textViewDidChange(_ textView: UITextView) {
        if textView.isFirstResponder { session.activate() }
        session.flushPending()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView.isFirstResponder { session.activate() }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text.isEmpty, let view = textView as? ComposerUITextView else { return true }
        return !view.deleteComposerCharacters(in: range)
    }
}

private final class ComposerUITextView: UITextView, ComposerNativeTextEditor, InlinePastedTextOpening {
    weak var composer: ComposerTextCoordinator?
    let composerTheme: AppThemeStore
    private let composerGraph: ComposerTextGraph
    private weak var document: ComposerDocument?
    var maximumLines = 6
    private var lastHeight: CGFloat = 0
    private lazy var sendCommand = Self.returnCommand(modifierFlags: [], action: #selector(sendComposer(_:)))
    private lazy var newlineCommands = [UIKeyModifierFlags.shift, .alternate].map { flags in
        Self.returnCommand(modifierFlags: flags, action: #selector(insertComposerNewline(_:)))
    }

    private static func returnCommand(modifierFlags: UIKeyModifierFlags, action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(input: "\r", modifierFlags: modifierFlags, action: action)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    init(graph: ComposerTextGraph, document: ComposerDocument, theme: AppThemeStore) {
        composerTheme = theme
        composerGraph = graph
        self.document = document
        super.init(frame: .zero, textContainer: graph.container)
        register([.onScrollingOutOfViewport, .onEditingInlineParagraphs], forTextAttachmentViewProviderType: InlinePastedTextViewProvider.self)
    }

    required init?(coder: NSCoder) { nil }

    override var undoManager: UndoManager? { document?.undoManager ?? super.undoManager }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { composer?.scheduleNativeSync(self) }
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + newlineCommands + (markedTextRange == nil ? [sendCommand] : [])
    }

    @objc private func sendComposer(_ sender: UIKeyCommand) {
        composer?.actions.send()
    }

    @objc private func insertComposerNewline(_ sender: UIKeyCommand) {
        guard markedTextRange == nil, let composer else { return }
        composer.session.activate()
        composer.session.document.edit(.insert(.init(runs: [.text("\n")])))
    }

    var composerSelection: NSRange {
        get { selectedRange }
        set { selectedRange = newValue }
    }
    var isComposing: Bool { markedTextRange != nil }
    var composerFontSize: CGFloat { font?.pointSize ?? UIFont.preferredFont(forTextStyle: .body).pointSize }
    var composerAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
    }
    func composerHeight(width: CGFloat) -> CGFloat {
        let lineHeight = ceil(font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight)
        let content = abs(width - bounds.width) > 0.5 && width > 0
            ? sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            : contentSize.height
        return min(max(ceil(content), lineHeight), lineHeight * CGFloat(maximumLines))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = composerHeight(width: bounds.width)
        guard abs(lastHeight - height) > 0.5 else { return }
        lastHeight = height
        invalidateIntrinsicContentSize()
    }

    func replaceComposerCharacters(in range: NSRange, with text: NSAttributedString, resetsUndo: Bool) {
        let previous = textStorage.attributedSubstring(from: range)
        let replacementRange = NSRange(location: range.location, length: text.length)
        if !resetsUndo {
            undoManager?.beginUndoGrouping()
            undoManager?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.replaceComposerCharacters(in: replacementRange, with: previous, resetsUndo: false)
                }
            }
        }
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: range, with: text)
        textStorage.endEditing()
        selectedRange = NSRange(location: range.location + text.length, length: 0)
        if resetsUndo { undoManager?.removeAllActions() }
        else { undoManager?.endUndoGrouping() }
        scrollRangeToVisible(selectedRange)
        invalidateIntrinsicContentSize()
    }

    func finishComposition() { unmarkText() }
    func openPastedText(_ id: UUID) { composer?.actions.openPastedText(id) }

    override func insertText(_ text: String) {
        clearPasteTypingAttributes()
        super.insertText(text)
    }

    override func deleteBackward() {
        let range = selectedRange.length > 0 ? selectedRange : NSRange(location: max(0, selectedRange.location - 1), length: selectedRange.location > 0 ? 1 : 0)
        if !deleteComposerCharacters(in: range) { super.deleteBackward() }
    }

    func deleteComposerCharacters(in range: NSRange) -> Bool {
        guard markedTextRange == nil, let composer else { return false }
        var containsPaste = false
        textStorage.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if value is any PastedTextReferencing { containsPaste = true; stop.pointee = true }
        }
        guard containsPaste else { return false }
        composer.session.activate()
        composer.session.document.edit(.replace(range, .init(runs: [])))
        return true
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        clearPasteTypingAttributes()
        super.setMarkedText(markedText, selectedRange: selectedRange)
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

    override func paste(_ sender: Any?) {
        guard let composer else { return super.paste(sender) }
        composer.session.activate()
        let paste = Pasteboard.composerPaste()
        if paste.hasAttachments { composer.actions.attach(paste) }
        if let text = paste.inlineText { insertText(text) }
    }

    override func copy(_ sender: Any?) {
        guard let document = composer?.session.document else { return }
        UIPasteboard.general.string = document.content(in: selectedRange).expandedText
    }

    override func cut(_ sender: Any?) {
        guard isEditable else { return }
        copy(sender)
        if let composer { composer.session.document.edit(.replace(selectedRange, .init(runs: []))) }
    }
}
