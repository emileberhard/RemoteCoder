#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

private struct InlineViewProviderResult: @unchecked Sendable {
    let provider: NSTextAttachmentViewProvider
}

@MainActor
final class InlinePastedTextAttachment: NSTextAttachment, PastedTextReferencing {
    let entry: PastedTextPromptBlock.Entry
    var pastedText: PastedTextPromptBlock.Entry { entry }
    let title: String
    let fontSize: CGFloat
    let theme: AppThemeStore
    let layoutBounds: CGRect

    init(entry: PastedTextPromptBlock.Entry, title: String, fontSize: CGFloat, theme: AppThemeStore) {
        self.entry = entry
        self.title = title
        self.fontSize = fontSize
        self.theme = theme
        layoutBounds = CGRect(x: 0, y: -fontSize * 0.2,
            width: min(220, max(72, CGFloat(title.utf16.count) * fontSize * 0.6 + 24)), height: ceil(fontSize * 1.4))
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
    }

    required init?(coder: NSCoder) { nil }

    #if os(macOS)
    nonisolated override func viewProvider(for parentView: NSView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        makeProvider(parent: parentView, location: location, textContainer: textContainer)
    }
    #else
    nonisolated override func viewProvider(for parentView: UIView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        makeProvider(parent: parentView, location: location, textContainer: textContainer)
    }
    #endif

    nonisolated private func makeProvider(parent: PasteParentView?, location: any NSTextLocation,
                                         textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider {
        nonisolated(unsafe) let attachment = self
        nonisolated(unsafe) let location = location
        nonisolated(unsafe) let container = textContainer
        return MainActor.assumeIsolated {
            InlineViewProviderResult(provider: InlinePastedTextViewProvider(attachment: attachment,
                parent: parent, location: location, textContainer: container))
        }.provider
    }
}

#if os(macOS)
private typealias PasteParentView = NSView
#else
private typealias PasteParentView = UIView
#endif

@MainActor
protocol InlinePastedTextOpening: AnyObject {
    func openPastedText(_ id: UUID)
}

@MainActor
final class InlinePastedTextViewProvider: NSTextAttachmentViewProvider {
    private weak var parent: PasteParentView?
    #if os(iOS)
    private var hosting: UIHostingController<AnyView>?
    #endif

    fileprivate init(attachment: NSTextAttachment, parent: PasteParentView?, location: any NSTextLocation, textContainer: NSTextContainer?) {
        self.parent = parent
        super.init(textAttachment: attachment, parentView: parent, textLayoutManager: textContainer?.textLayoutManager, location: location)
    }

    nonisolated override func loadView() {
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated { provider.loadTokenView() }
    }

    private func loadTokenView() {
        guard let attachment = textAttachment as? InlinePastedTextAttachment else { return }
        let id = attachment.entry.id
        let token = InlinePastedTextToken(title: attachment.title, fontSize: attachment.fontSize) { [weak self] in
            var view = self?.parent
            while let current = view {
                if let opener = current as? any InlinePastedTextOpening {
                    opener.openPastedText(id)
                    return
                }
                view = current.superview
            }
        }.environment(attachment.theme)
        #if os(macOS)
        view = NSHostingView(rootView: token)
        #else
        let controller = UIHostingController(rootView: AnyView(token))
        controller.view.backgroundColor = .clear
        hosting = controller
        view = controller.view
        #endif
        view?.frame = CGRect(origin: .zero, size: attachment.layoutBounds.size)
    }

    nonisolated override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        nonisolated(unsafe) let provider = self
        return MainActor.assumeIsolated { (provider.textAttachment as? InlinePastedTextAttachment)?.layoutBounds ?? .zero }
    }
}

@MainActor
func inlinePastedText(_ content: ComposerDocumentContent, titles: [UUID: String], attributes: [NSAttributedString.Key: Any],
                      fontSize: CGFloat, theme: AppThemeStore) -> NSAttributedString {
    let result = ComposerDocument.attributed(content)
    result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
    result.enumerateAttribute(ComposerDocument.pastedTextKey, in: NSRange(location: 0, length: result.length)) { value, range, _ in
        guard let entry = (value as? any PastedTextReferencing)?.pastedText else { return }
        let attachment = InlinePastedTextAttachment(entry: entry, title: titles[entry.id] ?? InlineMessageContent.title(for: entry.text),
            fontSize: fontSize, theme: theme)
        result.addAttribute(.attachment, value: attachment, range: range)
    }
    return result
}

@MainActor
func renderedInlinePastedText(_ content: RenderedInlineMessage, attributes: [NSAttributedString.Key: Any],
                      fontSize: CGFloat, theme: AppThemeStore) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "")
    for run in content.runs {
        switch run {
        case .text(let text):
            for span in text.runs {
                var styled = inlineTextAttributes(span.inlinePresentationIntent, base: attributes, fontSize: fontSize)
                if let link = span.link { styled[.link] = link }
                result.append(NSAttributedString(string: String(text[span.range].characters), attributes: styled))
            }
        case .paste(let entry):
            var styled = attributes
            styled[.attachment] = InlinePastedTextAttachment(entry: entry,
                title: content.source.titles[entry.id] ?? InlineMessageContent.title(for: entry.text),
                fontSize: fontSize, theme: theme)
            result.append(NSAttributedString(string: "\u{FFFC}", attributes: styled))
        }
    }
    return result
}

@MainActor
private func inlineTextAttributes(_ intent: InlinePresentationIntent?, base: [NSAttributedString.Key: Any],
                                  fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
    var attributes = base
    guard let intent else { return attributes }
    #if os(macOS)
    guard var font = base[.font] as? NSFont else { preconditionFailure("Inline text requires a base font") }
    if intent.contains(.code) { font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    #else
    guard var font = base[.font] as? UIFont else { preconditionFailure("Inline text requires a base font") }
    if intent.contains(.code) { font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    var traits = font.fontDescriptor.symbolicTraits
    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
    if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: fontSize) }
    #endif
    attributes[.font] = font
    if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    return attributes
}
