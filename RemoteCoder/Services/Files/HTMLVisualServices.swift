import Foundation

@MainActor
final class HTMLVisualServices {
    let documents: HTMLVisualDocumentCache
    let renderer: HTMLVisualRenderer

    init(directory: URL) {
        documents = HTMLVisualDocumentCache(directory: directory.appending(path: "documents"),
            writer: HTMLVisualDocumentFileWriter())
        renderer = HTMLVisualRenderer(cache: HTMLVisualPresentationCache(
            directory: directory.appending(path: "presentations"), clock: ContinuousClock()),
            webContent: HTMLVisualWebContent())
        renderer.startLoading()
    }
}

#if DEBUG
extension HTMLVisualServices {
    static func coldDirectory(_ name: String) -> URL {
        let directory = URL.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        do { try FileManager.default.removeItem(at: directory) }
        catch CocoaError.fileNoSuchFile {}
        catch { preconditionFailure("Cannot clear \(directory.path): \(error)") }
        return directory
    }
}
#endif
