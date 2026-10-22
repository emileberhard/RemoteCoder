import Foundation
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static func composerPaste() -> ComposerPaste<PastedImage> {
        #if os(iOS)
        ComposerPaste(fileURLs: [], images: images(on: .general), string: UIPasteboard.general.string)
        #else
        composerPaste(from: .general)
        #endif
    }

    #if os(iOS)
    private static func images(on pasteboard: UIPasteboard) -> [PastedImage] {
        (0..<pasteboard.numberOfItems).compactMap { index in
            let item = IndexSet(integer: index)
            let types = (pasteboard.types(forItemSet: item)?.first ?? []).compactMap { UTType($0) }
            guard let type = AgentImageFiles.preferredType(among: types),
                  let data = pasteboard.data(forPasteboardType: type.identifier, inItemSet: item)?.first else { return nil }
            return PastedImage(data: data, type: type)
        }
    }
    #endif

    #if os(macOS)
    static func composerPaste(from pasteboard: NSPasteboard) -> ComposerPaste<PastedImage> {
        ComposerPaste(fileURLs: fileURLs(on: pasteboard), images: images(on: pasteboard),
                      string: pasteboard.string(forType: .string))
    }

    static func composerDrop(from pasteboard: NSPasteboard) -> ComposerPaste<PastedImage> {
        ComposerPaste(fileURLs: fileURLs(on: pasteboard), images: images(on: pasteboard), string: nil)
    }

    static func carriesAttachments(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLsOnly)
            || (pasteboard.pasteboardItems ?? []).contains { imageType(of: $0) != nil }
    }

    private static var fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] { [.urlReadingFileURLsOnly: true] }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLsOnly) as? [URL] ?? []
    }

    private static func images(on pasteboard: NSPasteboard) -> [PastedImage] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let type = imageType(of: item),
                  let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier)) else { return nil }
            return PastedImage(data: data, type: type)
        }
    }

    private static func imageType(of item: NSPasteboardItem) -> UTType? {
        AgentImageFiles.preferredType(among: item.types.compactMap { UTType($0.rawValue) })
    }
    #endif
}
