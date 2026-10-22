import SwiftUI
import UIKit

struct InlineMessageText: UIViewRepresentable {
    let content: RenderedInlineMessage
    let open: (UUID) -> Void
    @Environment(AppThemeStore.self) private var theme

    func makeUIView(context: Context) -> InlineMessageUITextView {
        InlineMessageUITextView(content: content, theme: theme, open: open)
    }

    func updateUIView(_ view: InlineMessageUITextView, context: Context) {
        view.open = open
        view.apply(content: content)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: InlineMessageUITextView, context: Context) -> CGSize? {
        view.layout.measure(width: proposal.width ?? 320)
    }

}

final class InlineMessageUITextView: UITextView, InlinePastedTextOpening {
    let layout: InlineMessageLayout
    var open: (UUID) -> Void

    init(content: RenderedInlineMessage, theme: AppThemeStore, open: @escaping (UUID) -> Void) {
        layout = InlineMessageLayout(content: content, theme: theme)
        self.open = open
        super.init(frame: .zero, textContainer: layout.container)
        backgroundColor = .clear
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        textContainerInset = .zero
        register([.onScrollingOutOfViewport], forTextAttachmentViewProviderType: InlinePastedTextViewProvider.self)
        accessibilityIdentifier = "sent-inline-pastes"
    }

    required init?(coder: NSCoder) { nil }

    func apply(content: RenderedInlineMessage) {
        let font = UIFont.preferredFont(forTextStyle: .body)
        layout.configure(content: content, attributes: [.font: font, .foregroundColor: UIColor.label], fontSize: font.pointSize)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layout.displayWidthChanged(to: bounds.width)
    }

    func openPastedText(_ id: UUID) { open(id) }

    override func copy(_ sender: Any?) {
        UIPasteboard.general.string = ComposerDocument.content(in: textStorage, range: selectedRange).expandedText
    }
}
