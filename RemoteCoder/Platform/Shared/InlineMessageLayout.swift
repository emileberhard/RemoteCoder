#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

@MainActor
final class InlineMessageLayout {
    let contentStorage = NSTextContentStorage()
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private let manager = NSTextLayoutManager()
    private var content: RenderedInlineMessage
    private let theme: AppThemeStore
    private var fontSize: CGFloat = 0
    private var measurement: (width: CGFloat, size: CGSize)?

    init(content: RenderedInlineMessage, theme: AppThemeStore) {
        self.content = content
        self.theme = theme
        contentStorage.textStorage = NSTextStorage()
        contentStorage.addTextLayoutManager(manager)
        manager.textContainer = container
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
    }

    func configure(content: RenderedInlineMessage, attributes: [NSAttributedString.Key: Any], fontSize: CGFloat) {
        guard self.fontSize != fontSize || self.content != content else { return }
        self.content = content
        self.fontSize = fontSize
        measurement = nil
        let text = renderedInlinePastedText(content, attributes: attributes, fontSize: fontSize, theme: theme)
        contentStorage.textStorage?.setAttributedString(text)
    }

    func measure(width: CGFloat) -> CGSize {
        let width = max(1, width)
        if let measurement, measurement.width == width { return measurement.size }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: contentStorage.documentRange)
        let bounds = manager.usageBoundsForTextContainer
        let size = CGSize(width: min(width, max(1, ceil(bounds.maxX))), height: max(ceil(fontSize * 1.4), ceil(bounds.maxY)))
        measurement = (width, size)
        return size
    }

    func displayWidthChanged(to width: CGFloat) {
        guard width > 0, measurement?.size.width != width else { return }
        _ = measure(width: width)
    }

    isolated deinit { contentStorage.removeTextLayoutManager(manager) }
}
