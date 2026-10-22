@MainActor
final class ForegroundUploadContinuation: UploadContinuation {
    func begin(for uploads: FileAttachmentImports) {}

    func progressChanged(in uploads: FileAttachmentImports) {}
}
