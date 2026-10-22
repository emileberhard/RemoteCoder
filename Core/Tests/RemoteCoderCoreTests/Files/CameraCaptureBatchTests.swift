import Foundation
import Testing
@testable import RemoteCoderCore

struct CameraCaptureBatchTests {
    private let directory = URL.temporaryDirectory.appending(path: "camera-batch-\(UUID())")

    private func photo(_ id: String, data: String) throws -> URL {
        let file = directory.appending(path: "\(id)/Photo.heic")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data.utf8).write(to: file)
        return file
    }

    @Test func onlyDoneConfirmsPhotosAndKeepsTheirCaptureOrder() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try photo("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", data: "first original")
        _ = try photo("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", data: "removed original")
        let third = try photo("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", data: "third original")
        #expect(try CameraCaptureBatch.confirmedFiles(in: directory) == nil)

        try CameraCaptureBatch.confirm([first, third], in: directory)

        let confirmed = try #require(try CameraCaptureBatch.confirmedFiles(in: directory))
        #expect(confirmed == [first, third])
        #expect(try confirmed.map { try String(contentsOf: $0, encoding: .utf8) } == ["first original", "third original"])
        try CameraCaptureBatch.unconfirm(in: directory)
        #expect(try CameraCaptureBatch.confirmedFiles(in: directory) == nil)
        #expect(try String(contentsOf: first, encoding: .utf8) == "first original")
    }

    @Test @MainActor func appHandoffDeletesRemovedPhotosAndTheBatchDirectory() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try photo("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", data: "first")
        let removed = try photo("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", data: "removed")
        let second = try photo("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", data: "second")
        try await CameraCaptureBatch.discardPhoto(removed)
        #expect(!FileManager.default.fileExists(atPath: removed.deletingLastPathComponent().path))
        var imported: [URL] = []
        try await CameraCaptureBatch.importFiles([first, second], from: directory) { imported = $0 }
        defer { for file in imported { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try imported.map { try String(contentsOf: $0, encoding: .utf8) } == ["first", "second"])
        try FileManager.default.removeItem(at: imported[0].deletingLastPathComponent())
        #expect(try String(contentsOf: imported[1], encoding: .utf8) == "second")
    }

    @Test func rejectedAppHandoffRestoresTheOriginalFiles() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try photo("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", data: "first")
        let second = try photo("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", data: "second")
        await #expect(throws: CancellationError.self) {
            try await CameraCaptureBatch.importFiles([first, second], from: directory) { _ in throw CancellationError() }
        }
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
    }

    @Test func aManifestCannotImportAnUnrelatedFileOrDuplicateAPhoto() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try photo("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", data: "first")
        #expect(throws: CameraCaptureBatch.Invalid.self) {
            try CameraCaptureBatch.confirm([first, first], in: directory)
        }
        let manifest = directory.appending(path: "ConfirmedPhotos.json")
        for paths in [["../private.txt"], ["/private.txt"], ["BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB/Photo.heic", "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB/Photo.heic"]] {
            try JSONEncoder().encode(paths).write(to: manifest)
            #expect(throws: CameraCaptureBatch.Invalid.self) { try CameraCaptureBatch.confirmedFiles(in: directory) }
        }
    }
}
