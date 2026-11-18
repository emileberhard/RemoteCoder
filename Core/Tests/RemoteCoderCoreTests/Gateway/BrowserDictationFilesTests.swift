import Foundation
import Testing
@testable import RemoteCoderCore

struct BrowserDictationFilesTests {
    @Test func preparationIsLazyAndDoesNotRemoveActiveWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "browser", directoryHint: .isDirectory)
        let files = BrowserDictationFiles(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appending(path: "stale.wav")
        try Data([0]).write(to: stale)
        let first = try await files.begin()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let payload = first.appending(path: "audio.wav")
        try Data([1, 2, 3]).write(to: payload)
        await #expect(throws: (any Error).self) { try await files.begin() }
        #expect(FileManager.default.fileExists(atPath: payload.path))
        try await files.finish(first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        let second = try await files.begin()
        #expect(second != first)
        try await files.finish(second)
    }

    @Test func failedPreparationCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appending(path: "blocker")
        try Data([1]).write(to: blocker)
        let files = BrowserDictationFiles(directory: blocker.appending(path: "browser", directoryHint: .isDirectory))
        await #expect(throws: (any Error).self) { try await files.begin() }
        try FileManager.default.removeItem(at: blocker)
        let work = try await files.begin()
        #expect(FileManager.default.fileExists(atPath: work.path))
        try await files.finish(work)
    }
}
