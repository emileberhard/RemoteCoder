import Foundation

protocol HTMLVisualDocumentWriting: Sendable {
    func writeReadOnlyTemporary(_ data: Data, to url: URL) async throws
}

struct HTMLVisualDocumentFileWriter: HTMLVisualDocumentWriting {
    @concurrent
    func writeReadOnlyTemporary(_ data: Data, to url: URL) async throws {
        try Task.checkCancellation()
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
    }
}
