import Foundation

/// Owns the local copies of picked files until the gateway has them. The
/// picker's security-scoped access ends with its callback, while an upload
/// may outlive the view, the scene, or the process, so the bytes are
/// snapshotted under `<directory>/<attachment id>/<name>` first.
struct UploadStaging: Sendable {
    let directory: URL

    struct StagedFile: Sendable, Equatable {
        let fileName: String
        let byteCount: Int64
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @concurrent
    func prepare(_ source: URL, id: UUID) async throws -> StagedFile {
        try stage(id: id) { target in try Self.copy(source, into: target) }
    }

    @concurrent
    func adopt(_ file: URL, id: UUID) async throws -> StagedFile {
        try stage(id: id) { target in
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return try Self.copy(file, into: target) }
            let destination = target.appending(path: file.lastPathComponent)
            do { try FileManager.default.moveItem(at: file, to: destination) }
            catch { throw Failure(message: "Could not prepare \(file.lastPathComponent): \(error.localizedDescription)") }
            return destination
        }
    }

    private func stage(id: UUID, placing place: (URL) throws -> URL) throws -> StagedFile {
        try Task.checkCancellation()
        let target = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        remove(id: id)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let file = try AgentImageFiles.readable(try place(target))
            let byteCount = Int64((try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard byteCount > 0 else { throw Failure(message: "\(file.lastPathComponent) is empty.") }
            try Task.checkCancellation()
            return StagedFile(fileName: file.lastPathComponent, byteCount: byteCount)
        } catch {
            remove(id: id)
            throw error
        }
    }

    /// Snapshots `source` for upload. A folder arrives zipped, which is what
    /// the coordinator's upload snapshot produces, and is named accordingly.
    private static func copy(_ source: URL, into target: URL) throws -> URL {
        let hasScopedAccess = source.startAccessingSecurityScopedResource()
        defer { if hasScopedAccess { source.stopAccessingSecurityScopedResource() } }
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let destination = target.appending(path: isDirectory ? source.lastPathComponent + ".zip" : source.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .forUploading, error: &coordinationError) { snapshot in
            do { try FileManager.default.copyItem(at: snapshot, to: destination) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError {
            throw Failure(message: "Could not copy \(source.lastPathComponent): \(error.localizedDescription)")
        }
        return destination
    }

    /// The staged copy, or nil once the attachment is on the host.
    func url(for attachment: ComposerFileAttachment) -> URL? {
        guard case .staged(let fileName) = attachment.placement else { return nil }
        return directory.appending(path: attachment.id.uuidString, directoryHint: .isDirectory).appending(path: fileName)
    }

    func remove(id: UUID) {
        try? FileManager.default.removeItem(at: directory.appending(path: id.uuidString, directoryHint: .isDirectory))
    }
}
