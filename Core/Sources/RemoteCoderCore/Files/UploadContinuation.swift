@MainActor
protocol UploadContinuation: AnyObject {
    func begin(for uploads: FileAttachmentImports)
    func progressChanged(in uploads: FileAttachmentImports)
}
