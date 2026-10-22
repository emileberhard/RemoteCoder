#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

extension View {
    func composerAttachmentDrop(screen: ChatScreenModel) -> some View {
        modifier(ComposerAttachmentDropModifier(screen: screen))
    }
}

private struct ComposerAttachmentDropModifier: ViewModifier {
    let screen: ChatScreenModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .environment(\.isAttachmentDropTargeted, isTargeted)
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted, perform: drop)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard screen.acceptsAttachments, let draft = screen.currentDraft else { return false }
        let files = providers.compactMap { provider -> DeferredImportFile? in
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                return .borrowed { try await Self.fileURL(from: provider) }
            }
            return AgentImageFiles.preferredType(among: provider.registeredContentTypes).map { type in
                .inOwnDirectory { try await Self.file(from: provider, type: type) }
            }
        }
        guard !files.isEmpty else { return false }
        screen.importFiles(files, for: draft)
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async throws -> URL {
        try await loaded { delivery in
            provider.loadObject(ofClass: URL.self) { url, error in
                if let url, url.isFileURL {
                    delivery.yield(url)
                    delivery.finish()
                } else {
                    delivery.finish(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private static func file(from provider: NSItemProvider, type: UTType) async throws -> URL {
        try await loaded { delivery in
            provider.loadFileRepresentation(for: type) { url, _, error in
                do {
                    guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                    let copy = try DeferredImportFile.scratchCopy(of: url)
                    if case .terminated = delivery.yield(copy) { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
                    delivery.finish()
                } catch {
                    delivery.finish(throwing: error)
                }
            }
        }
    }

    private static func loaded(_ start: (AsyncThrowingStream<URL, Error>.Continuation) -> Progress) async throws -> URL {
        let (values, delivery) = AsyncThrowingStream<URL, Error>.makeStream()
        let progress = start(delivery)
        delivery.onTermination = { _ in progress.cancel() }
        for try await value in values { return value }
        throw CancellationError()
    }
}
#endif
