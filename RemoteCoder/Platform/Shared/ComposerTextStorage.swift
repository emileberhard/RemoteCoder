#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

private struct TextStorageAttributes: @unchecked Sendable {
    let values: [NSAttributedString.Key: Any]
}

@MainActor
final class ComposerTextStorage: NSTextStorage {
    private let backing: NSMutableAttributedString
    private weak var document: ComposerDocument?
    weak var contentStorage: NSTextContentStorage?

    init(document: ComposerDocument, theme: AppThemeStore, fontSize: CGFloat) {
        let value = NSMutableAttributedString(attributedString: document.buffer)
        value.enumerateAttribute(ComposerDocument.pastedTextKey, in: NSRange(location: 0, length: value.length)) { attachment, range, _ in
            guard let entry = (attachment as? any PastedTextReferencing)?.pastedText, !(attachment is InlinePastedTextAttachment) else { return }
            value.addAttribute(.attachment, value: InlinePastedTextAttachment(entry: entry,
                title: InlineMessageContent.title(for: entry.text), fontSize: fontSize, theme: theme), range: range)
        }
        backing = value
        self.document = document
        super.init()
    }

    required init?(coder: NSCoder) { nil }
    #if os(macOS)
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { nil }
    #endif

    nonisolated override var string: String {
        nonisolated(unsafe) let storage = self
        return MainActor.assumeIsolated { storage.backing.string }
    }

    nonisolated override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        nonisolated(unsafe) let storage = self
        nonisolated(unsafe) let pointer = range
        return MainActor.assumeIsolated {
            TextStorageAttributes(values: storage.backing.attributes(at: location, effectiveRange: pointer))
        }.values
    }

    nonisolated override func replaceCharacters(in range: NSRange, with string: String) {
        nonisolated(unsafe) let storage = self
        MainActor.assumeIsolated {
            let removed = storage.backing.attributedSubstring(from: range).string
            storage.beginEditing()
            storage.backing.replaceCharacters(in: range, with: string)
            storage.edited(.editedCharacters, range: range, changeInLength: (string as NSString).length - range.length)
            if storage.document?.buffer === storage { storage.document?.changedCharacters(in: range, removed: removed, inserted: string) }
            storage.endEditing()
        }
    }

    nonisolated override func setAttributes(_ attributes: [NSAttributedString.Key: Any]?, range: NSRange) {
        nonisolated(unsafe) let storage = self
        nonisolated(unsafe) let values = attributes
        MainActor.assumeIsolated {
            let replacement = values?[.attachment] as? any PastedTextReferencing
            var changesPaste = false
            storage.backing.enumerateAttribute(.attachment, in: range) { old, _, _ in
                if let reference = old as? any PastedTextReferencing {
                    if reference !== replacement, reference.pastedText != replacement?.pastedText { changesPaste = true }
                } else if replacement != nil { changesPaste = true }
            }
            storage.beginEditing()
            storage.backing.setAttributes(values, range: range)
            storage.edited(.editedAttributes, range: range, changeInLength: 0)
            if changesPaste, storage.document?.buffer === storage { storage.document?.changedPasteAttributes() }
            storage.endEditing()
        }
    }
}

@MainActor
final class ComposerTextGraph {
    let contentStorage: NSTextContentStorage
    let layoutManager = NSTextLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    let storage: ComposerTextStorage

    init(document: ComposerDocument, theme: AppThemeStore, fontSize: CGFloat) {
        if let existing = document.buffer as? ComposerTextStorage, let contentStorage = existing.contentStorage {
            storage = existing
            self.contentStorage = contentStorage
        } else {
            storage = ComposerTextStorage(document: document, theme: theme, fontSize: fontSize)
            contentStorage = NSTextContentStorage()
            contentStorage.textStorage = storage
            storage.contentStorage = contentStorage
        }
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = container
    }

    isolated deinit { contentStorage.removeTextLayoutManager(layoutManager) }
}
