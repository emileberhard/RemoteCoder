import Foundation
import UIKit
import UniformTypeIdentifiers

enum SharedItem: Sendable {
    case file(String)
    case text(String)
}

extension NSItemProvider {
    func loadSharedItem(into share: SharedItemsInbox.Share, maximumBytes: Int) async throws -> SharedItem {
        guard let primary = registeredContentTypes.first else { throw CocoaError(.fileReadUnsupportedScheme) }
        if primary.conforms(to: .url) { return try await loadLink(into: share, maximumBytes: maximumBytes) }
        if isText(primary) { return try await loadText() }
        return try await loadFile(primary, into: share, maximumBytes: maximumBytes)
    }

    private func isText(_ primary: UTType) -> Bool {
        guard primary.conforms(to: .plainText) else { return false }
        switch preferredPresentationStyle {
        case .inline: return true
        case .attachment: return false
        case .unspecified: return primary == .plainText || primary == .utf8PlainText
        @unknown default: return false
        }
    }

    private func loadLink(into share: SharedItemsInbox.Share, maximumBytes: Int) async throws -> SharedItem {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                continuation.resume(with: Result {
                    guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                    return url.isFileURL ? .file(try share.copy(url, maximumBytes: maximumBytes)) : .text(url.absoluteString)
                })
            }
        }
    }

    private func loadText() async throws -> SharedItem {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: String.self) { text, error in
                continuation.resume(with: Result {
                    guard let text else { throw error ?? CocoaError(.fileReadUnknown) }
                    return .text(text)
                })
            }
        }
    }

    private func loadFile(_ type: UTType, into share: SharedItemsInbox.Share, maximumBytes: Int) async throws -> SharedItem {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadFileRepresentation(for: type) { url, _, error in
                continuation.resume(with: Result {
                    guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                    return .file(try share.move(url, maximumBytes: maximumBytes))
                })
            }
        }
    }
}
