import Foundation

actor BrowserDictationFiles {
    private let directory: URL
    private var prepared = false
    private var pendingCleanup: URL?
    private var cleanupFailed = false

    init(directory: URL) { self.directory = directory }

    func begin() throws -> URL {
        let manager = FileManager.default
        if !prepared {
            if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            prepared = true
        }
        if let pendingCleanup {
            guard cleanupFailed else { throw CocoaError(.fileWriteFileExists) }
            if manager.fileExists(atPath: pendingCleanup.path) { try manager.removeItem(at: pendingCleanup) }
            self.pendingCleanup = nil
            cleanupFailed = false
        }
        let work = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        pendingCleanup = work
        do {
            try manager.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            cleanupFailed = true
            throw error
        }
        return work
    }

    func finish(_ work: URL) throws {
        guard pendingCleanup == work, !cleanupFailed else { throw CocoaError(.fileWriteUnknown) }
        do {
            try FileManager.default.removeItem(at: work)
            pendingCleanup = nil
        } catch {
            cleanupFailed = true
            throw error
        }
    }
}
