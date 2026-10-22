#if os(macOS)
import AppKit
import SwiftUI

struct InlineMessageText: NSViewRepresentable {
    let content: RenderedInlineMessage
    let open: (UUID) -> Void
    @Environment(AppThemeStore.self) private var theme
    @Environment(\.interfaceScale) private var scale

    func makeNSView(context: Context) -> InlineMessageNSTextView {
        InlineMessageNSTextView(content: content, theme: theme, open: open)
    }

    func updateNSView(_ view: InlineMessageNSTextView, context: Context) {
        view.open = open
        view.apply(content: content, scale: scale)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: InlineMessageNSTextView, context: Context) -> CGSize? {
        view.layout.measure(width: proposal.width ?? 320)
    }

}

final class InlineMessageNSTextView: NSTextView, InlinePastedTextOpening {
    let layout: InlineMessageLayout
    var open: (UUID) -> Void

    init(content: RenderedInlineMessage, theme: AppThemeStore, open: @escaping (UUID) -> Void) {
        layout = InlineMessageLayout(content: content, theme: theme)
        self.open = open
        super.init(frame: .zero, textContainer: layout.container)
        drawsBackground = false
        isEditable = false
        isSelectable = true
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        register([.onScrollingOutOfViewport], forTextAttachmentViewProviderType: InlinePastedTextViewProvider.self)
        setAccessibilityIdentifier("sent-inline-pastes")
    }

    required init?(coder: NSCoder) { nil }

    func apply(content: RenderedInlineMessage, scale: CGFloat) {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let font = body.withSize(body.pointSize * scale)
        layout.configure(content: content, attributes: [.font: font, .foregroundColor: NSColor.labelColor], fontSize: font.pointSize)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layout.displayWidthChanged(to: newSize.width)
    }

    func openPastedText(_ id: UUID) { open(id) }

    override func copy(_ sender: Any?) {
        guard let textStorage else { return }
        let text = ComposerDocument.content(in: textStorage, range: selectedRange()).expandedText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
