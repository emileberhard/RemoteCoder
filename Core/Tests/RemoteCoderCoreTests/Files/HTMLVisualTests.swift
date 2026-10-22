import Foundation
import Testing
@testable import RemoteCoderCore

struct HTMLVisualTests {
    private let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test func referencesAcceptOnlyCanonicalDigests() throws {
        let digest = emptyDigest
        let valid = try #require(URL(string: "rc-visual:" + digest))
        #expect(HTMLVisualReference(url: valid)?.digest == digest)
        let invalid = [
            "RC-visual:" + digest, "rc-visual://" + digest, "rc-visual:" + digest.uppercased(),
            "rc-visual:" + digest + "?x=1", "rc-visual:" + digest + "#anchor",
            "rc-visual:" + String(digest.dropLast()), "rc-visual:%65" + String(digest.dropFirst()),
            "rc-visual:" + String(repeating: "g", count: 64),
        ]
        for value in invalid {
            let url = try #require(URL(string: value))
            #expect(HTMLVisualReference(url: url) == nil)
        }
    }

    @Test func markdownReferencesFollowTheGatewayEmbedOncePerDigest() {
        let other = String(repeating: "a", count: 64)
        let text = "![One](rc-visual:\(emptyDigest)) text ![Two](rc-visual:\(other)) ![Again](rc-visual:\(emptyDigest)) "
            + "![Short](rc-visual:abc) [plain](https://example.com)"
        #expect(HTMLVisualReference.references(inMarkdown: text).map(\.digest) == [emptyDigest, other])
    }

    @Test func verificationRejectsChangedBytesEncodingAndOversize() throws {
        let url = try #require(URL(string: "rc-visual:" + emptyDigest))
        let reference = try #require(HTMLVisualReference(url: url))
        #expect(try reference.verify(Data()) == "")
        #expect(throws: HTMLVisualError.digestMismatch) { try reference.verify(Data("changed".utf8)) }
        #expect(throws: HTMLVisualError.invalidUTF8) { try reference.verify(Data([0xff])) }
        #expect(throws: HTMLVisualError.tooLarge) {
            try reference.verify(Data(repeating: 65, count: (2 << 20) + 1))
        }
    }

    @Test func verifiedCopySurvivesSourceDeletionAndStoreRecreation() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.html")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: source)
        let cacheDirectory = directory.appending(path: "cache", directoryHint: .isDirectory)
        let url = try #require(URL(string: "rc-visual:" + emptyDigest))
        let reference = try #require(HTMLVisualReference(url: url))
        let hostID = UUID()
        let cache = HTMLVisualDocumentCache(directory: cacheDirectory, writer: HTMLVisualDocumentFileWriter())
        #expect(try await cache.store(hostID: hostID, reference: reference, source: source) == "")
        try FileManager.default.removeItem(at: source)
        let restored = HTMLVisualDocumentCache(directory: cacheDirectory, writer: HTMLVisualDocumentFileWriter())
        #expect(try await restored.document(hostID: hostID, reference: reference) == "")
        #expect(try await restored.document(hostID: UUID(), reference: reference) == nil)
        let saved = try #require(FileManager.default.contentsOfDirectory(at: cacheDirectory,
            includingPropertiesForKeys: nil).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
    }

    @Test func failedVerificationDoesNotPublishCopy() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "source.html")
        try Data("changed".utf8).write(to: source)
        let url = try #require(URL(string: "rc-visual:" + emptyDigest))
        let reference = try #require(HTMLVisualReference(url: url))
        let cache = HTMLVisualDocumentCache(directory: directory.appending(path: "cache"), writer: HTMLVisualDocumentFileWriter())
        let hostID = UUID()
        await #expect(throws: HTMLVisualError.digestMismatch) {
            try await cache.store(hostID: hostID, reference: reference, source: source)
        }
        #expect(try await cache.document(hostID: hostID, reference: reference) == nil)
    }

    @Test func persistentBudgetEvictsOldestAcrossHosts() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "source.html")
        try Data(repeating: 65, count: 2 << 20).write(to: source)
        let digest = "5b766f6d76a999636fd93b4e039d5a32187f84a19c0950449f0c721da0223914"
        let url = try #require(URL(string: "rc-visual:" + digest))
        let reference = try #require(HTMLVisualReference(url: url))
        let cache = HTMLVisualDocumentCache(directory: directory.appending(path: "cache"), writer: HTMLVisualDocumentFileWriter())
        let hosts = (0..<33).map { _ in UUID() }
        for (index, host) in hosts.enumerated() {
            _ = try await cache.store(hostID: host, reference: reference, source: source)
            let saved = directory.appending(path: "cache")
                .appending(path: host.uuidString + "-" + digest + ".html")
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: Double(index))],
                ofItemAtPath: saved.path)
        }
        #expect(try await cache.document(hostID: hosts[0], reference: reference) == nil)
        #expect(try await cache.document(hostID: hosts[1], reference: reference)?.utf8.count == 2 << 20)
        #expect(try await cache.document(hostID: hosts[32], reference: reference)?.utf8.count == 2 << 20)
    }

    @Test func cancellationAfterTemporaryWriteCannotPublishOrLeakCopy() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "source.html")
        try Data().write(to: source)
        let url = try #require(URL(string: "rc-visual:" + emptyDigest))
        let reference = try #require(HTMLVisualReference(url: url))
        let writer = PausedDocumentWriter()
        let cacheDirectory = directory.appending(path: "cache")
        let cache = HTMLVisualDocumentCache(directory: cacheDirectory, writer: writer)
        let hostID = UUID()
        let work = Task { try await cache.store(hostID: hostID, reference: reference, source: source) }
        let temporary = await writer.prepared()
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
        work.cancel()
        await writer.finish()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try await cache.document(hostID: hostID, reference: reference) == nil)
        #expect(try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil).isEmpty)
    }
}

private actor PausedDocumentWriter: HTMLVisualDocumentWriting {
    private var url: URL?
    private var observer: CheckedContinuation<URL, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func writeReadOnlyTemporary(_ data: Data, to url: URL) async throws {
        try await HTMLVisualDocumentFileWriter().writeReadOnlyTemporary(data, to: url)
        await withCheckedContinuation { continuation in
            completion = continuation
            self.url = url
            observer?.resume(returning: url)
            observer = nil
        }
    }

    func prepared() async -> URL {
        if let url { return url }
        return await withCheckedContinuation { observer = $0 }
    }

    func finish() {
        completion?.resume()
        completion = nil
    }
}
