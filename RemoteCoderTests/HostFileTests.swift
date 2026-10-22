import Foundation
import Testing
@testable import RemoteCoder

struct GatewayFileDownloadClientTests {
    @Test func visualMetadataRequiresDigestFilenameAndOwnedByteCap() throws {
        let url = try #require(URL(string: "rc-visual:" + String(repeating: "a", count: 64)))
        let reference = try #require(HTMLVisualReference(url: url))
        let source = GatewayFileDownloadSource.visual(reference)
        try source.validate(HostFileMetadata(path: "/changed/layout/" + reference.digest + ".html", name: reference.digest + ".html", bytes: 42, modifiedAt: 1, revision: "v1"))
        #expect(throws: HostFileError.invalidResponse) {
            try source.validate(HostFileMetadata(path: "/changed/layout/other.html", name: "other.html", bytes: 42, modifiedAt: 1, revision: "v1"))
        }
        #expect(throws: HostFileError.tooLarge) {
            try source.validate(HostFileMetadata(path: "/changed/layout/" + reference.digest + ".html", name: reference.digest + ".html", bytes: Int64(HTMLVisualReference.maximumBytes + 1), modifiedAt: 1, revision: "v1"))
        }
    }

    @Test func distinguishesGatewayAuthorizationFromMacFilePermissions() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"kind":"accessDenied","message":"Permission denied"}"#.utf8).write(to: file)
        #expect(try GatewayFileDownloadClient.responseError(403, file: file) == .accessDenied)
        try Data(#"{"error":"Unauthorized"}"#.utf8).write(to: file)
        #expect(try GatewayFileDownloadClient.responseError(401, file: file) == .unauthorized)
    }

    @Test func validatesMetadataAgainstTheRequestedPathAndExactLength() throws {
        let url = try #require(URL(string: "https://example.com/files/download"))
        let metadata = HostFileMetadata(path: "/tmp/file", name: "file", bytes: 3, modifiedAt: 1, revision: "v1")
        let header = try JSONEncoder().encode(metadata).base64EncodedString()
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["X-RemoteCoder-File-Metadata": header, "Content-Length": "4"]))
        #expect(throws: HostFileError.invalidResponse) {
            try GatewayFileDownloadClient.metadata(from: response, source: .file(path: "/tmp/file", containingDirectory: nil))
        }
        let matching = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["X-RemoteCoder-File-Metadata": header, "Content-Length": "3"]))
        #expect(try GatewayFileDownloadClient.metadata(from: matching, source: .file(path: "/tmp/file", containingDirectory: nil)) == metadata)
        #expect(throws: HostFileError.invalidResponse) {
            try GatewayFileDownloadClient.metadata(from: matching, source: .file(path: "/other/file", containingDirectory: nil))
        }
    }
}

struct HostFileStoreTests {
    @Test func visualAcquisitionUsesOpaqueDigestAndServerResolvedMetadata() async throws {
        let fixture = try Fixture(steps: [.file(Data("<p>visual</p>".utf8), "v1")], cacheBytes: 32)
        defer { fixture.remove() }
        let url = try #require(URL(string: "rc-visual:" + String(repeating: "a", count: 64)))
        let reference = try #require(HTMLVisualReference(url: url))
        let lease = try await fixture.store.openVisual(reference: reference, progress: { _ in })
        #expect(lease.reference.path == "/different/store/" + reference.digest + ".html")
        #expect(try Data(contentsOf: lease.url) == Data("<p>visual</p>".utf8))
        let source = try #require(await fixture.downloader.sources.first)
        guard case .visual(let actual) = source else { Issue.record("Expected digest download"); return }
        #expect(actual == reference)
        await fixture.store.release(lease)
    }

    @Test func revalidationReusesImmutableBytesWithIndependentLeases() async throws {
        let fixture = try Fixture(steps: [.file(Data("one".utf8), "v1"), .unchanged(Data("one".utf8), "v1")], cacheBytes: 32)
        defer { fixture.remove() }
        let reference = try fixture.reference("file.txt")
        let first = try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        let second = try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        #expect(first.url == second.url)
        #expect(first.id != second.id)
        #expect(first.downloadedAt == second.downloadedAt)
        #expect(await fixture.downloader.revisions == [nil, "v1"])
        await fixture.store.release(first)
        #expect(try Data(contentsOf: second.url) == Data("one".utf8))
        await fixture.store.retire()
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        await fixture.store.release(second)
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
    }

    @Test func changedRevisionDoesNotOverwriteAnOpenFile() async throws {
        let fixture = try Fixture(steps: [.file(Data("old".utf8), "v1"), .file(Data("new".utf8), "v2")], cacheBytes: 32)
        defer { fixture.remove() }
        let reference = try fixture.reference("same.txt")
        let first = try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        let second = try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        #expect(first.url != second.url)
        #expect(try Data(contentsOf: first.url) == Data("old".utf8))
        #expect(try Data(contentsOf: second.url) == Data("new".utf8))
        await fixture.store.release(first)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        await fixture.store.release(second)
        await fixture.store.retire()
    }

    @Test func failedRevalidationRequiresExplicitCachedCopyAcquisition() async throws {
        let fixture = try Fixture(steps: [.file(Data("saved".utf8), "v1"), .failure(.missing)], cacheBytes: 32)
        defer { fixture.remove() }
        let reference = try fixture.reference("report.txt")
        let original = try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        await fixture.store.release(original)
        await #expect(throws: HostFileError.missing) {
            try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        }
        let saved = try #require(await fixture.store.cachedCopy(for: reference))
        #expect(saved.id != original.id)
        #expect(saved.downloadedAt == original.downloadedAt)
        #expect(try Data(contentsOf: saved.url) == Data("saved".utf8))
        await fixture.store.release(saved)
        await fixture.store.retire()
    }

    @Test func oversizedCacheEntrySurvivesOnlyWhileHeld() async throws {
        let fixture = try Fixture(steps: [.file(Data("large".utf8), "v1")], cacheBytes: 2)
        defer { fixture.remove() }
        let reference = try fixture.reference("large.bin")
        let preview = try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        let export = try #require(await fixture.store.cachedCopy(for: reference))
        await fixture.store.release(preview)
        #expect(FileManager.default.fileExists(atPath: export.url.path))
        await fixture.store.release(export)
        #expect(!FileManager.default.fileExists(atPath: export.url.path))
        #expect(try await fixture.store.cachedCopy(for: reference) == nil)
        await fixture.store.retire()
    }

    @Test func evictsLeastRecentlyUsedUnheldFiles() async throws {
        let fixture = try Fixture(steps: [.file(Data("aaa".utf8), "a"), .file(Data("bbb".utf8), "b")], cacheBytes: 3)
        defer { fixture.remove() }
        let first = try await fixture.store.open(reference: fixture.reference("a"), containingDirectory: nil, progress: { _ in })
        await fixture.store.release(first)
        let second = try await fixture.store.open(reference: fixture.reference("b"), containingDirectory: nil, progress: { _ in })
        await fixture.store.release(second)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        await fixture.store.retire()
    }

    @Test func emptyFilesRemainValidAndHostIdentityIsExact() async throws {
        let fixture = try Fixture(steps: [.file(Data(), "empty")], cacheBytes: 32)
        defer { fixture.remove() }
        let otherHost = try HostFileReference(hostID: UUID(), path: "/tmp/empty")
        await #expect(throws: HostFileError.wrongHost) {
            try await fixture.store.open(reference: otherHost, containingDirectory: nil, progress: { _ in })
        }
        let empty = try await fixture.store.open(reference: fixture.reference("empty"), containingDirectory: nil, progress: { _ in })
        #expect(try Data(contentsOf: empty.url).isEmpty)
        #expect(empty.metadata.bytes == 0)
        await fixture.store.release(empty)
        await fixture.store.retire()
    }

    @Test func cancellationCleansPartialData() async throws {
        let started = Signal()
        let fixture = try Fixture(steps: [.suspended(started)], cacheBytes: 32)
        defer { fixture.remove() }
        let reference = try fixture.reference("partial")
        let opening = Task { try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in }) }
        await started.wait()
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        let directories = await fixture.downloader.directories
        #expect(!directories.isEmpty)
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try await fixture.store.cachedCopy(for: reference) == nil)
        await fixture.store.retire()
    }

    @Test func retirementFencesLateDownloadPublication() async throws {
        let started = Signal()
        let finish = Signal()
        let fixture = try Fixture(steps: [.late(started, finish)], cacheBytes: 32)
        defer { fixture.remove() }
        let reference = try fixture.reference("late")
        let opening = Task { try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in }) }
        await started.wait()
        fixture.store.beginRetirement()
        await finish.signal()
        await #expect(throws: HostFileError.retired) { try await opening.value }
        let directories = await fixture.downloader.directories
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        await fixture.store.retire()
    }

    @Test func restoresCompletedCacheAcrossRelaunchAndSweepsPartialDownloads() async throws {
        let fixture = try Fixture(steps: [.file(Data("saved".utf8), "v1")], cacheBytes: 32)
        defer { fixture.remove() }
        let reference = try fixture.reference("record.json")
        let first = try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        await fixture.store.release(first)
        let partial = fixture.root.appending(path: fixture.hostID.uuidString)
            .appending(path: UUID().uuidString).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partial.appending(path: "unfinished"))
        let relaunched = HostFileDiskBudget(root: fixture.root, workingSetBytes: 1024, diskHeadroomBytes: 0,
                                           availableCapacity: { _ in 10_000 })
        let store = HostFileStore(hostID: fixture.hostID, connectionID: String(repeating: "a", count: 64),
                                  downloader: Downloader(steps: [.unchanged(Data("saved".utf8), "v1")]),
                                  budget: relaunched, cacheBytes: 32)
        let cached = try #require(await store.cachedCopy(for: reference))
        #expect(cached.url == first.url)
        #expect(cached.downloadedAt == first.downloadedAt)
        #expect(try Data(contentsOf: cached.url) == Data("saved".utf8))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let checked = try await store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        #expect(checked.url == first.url)
        await store.release(cached)
        await store.release(checked)
        await store.retire()
    }

    @Test func unusableCachedBytesAreRemovedWithoutLeavingAPin() async throws {
        let fixture = try Fixture(steps: [.file(Data("valid".utf8), "v1")], cacheBytes: 32)
        defer { fixture.remove() }
        let reference = try fixture.reference("file.txt")
        let lease = try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        await fixture.store.release(lease)
        try Data("truncated".utf8).write(to: lease.url)
        #expect(try await fixture.store.cachedCopy(for: reference) == nil)
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
        await fixture.store.retire()
    }

    @Test func changedConnectionCannotAdoptAnEarlierCachedCopy() async throws {
        let fixture = try Fixture(steps: [.file(Data("old host".utf8), "v1")], cacheBytes: 32)
        defer { fixture.remove() }
        let reference = try fixture.reference("same.txt")
        let first = try await fixture.store.open(reference: reference, containingDirectory: nil, progress: { _ in })
        await fixture.store.release(first)
        let relaunched = HostFileDiskBudget(root: fixture.root, workingSetBytes: 1024, diskHeadroomBytes: 0,
                                           availableCapacity: { _ in 10_000 })
        let store = HostFileStore(hostID: fixture.hostID, connectionID: String(repeating: "b", count: 64),
                                  downloader: Downloader(steps: []), budget: relaunched, cacheBytes: 32)
        #expect(try await store.cachedCopy(for: reference) == nil)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        await store.retire()
    }

    @Test func diskPressureEvictsOtherHostsUnheldFilesButNeverPins() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = HostFileDiskBudget(root: root, workingSetBytes: 8, diskHeadroomBytes: 0,
                                       availableCapacity: { _ in 100 })
        let firstHost = UUID(), secondHost = UUID()
        let first = HostFileStore(hostID: firstHost, connectionID: String(repeating: "a", count: 64),
                                  downloader: Downloader(steps: [.file(Data("12345".utf8), "v1")]), budget: budget, cacheBytes: 32)
        let second = HostFileStore(hostID: secondHost, connectionID: String(repeating: "b", count: 64),
                                   downloader: Downloader(steps: [.file(Data("67890".utf8), "v2"), .file(Data("67890".utf8), "v2")]),
                                   budget: budget, cacheBytes: 32)
        let reference = try HostFileReference(hostID: firstHost, path: "/tmp/same")
        let otherReference = try HostFileReference(hostID: secondHost, path: "/tmp/same")
        let held = try await first.open(reference: reference, containingDirectory: nil, progress: { _ in })
        await #expect(throws: HostFileError.busy) { try await second.open(reference: otherReference, containingDirectory: nil, progress: { _ in }) }
        #expect(FileManager.default.fileExists(atPath: held.url.path))
        await first.release(held)
        let next = try await second.open(reference: otherReference, containingDirectory: nil, progress: { _ in })
        #expect(!FileManager.default.fileExists(atPath: held.url.path))
        #expect(try await first.cachedCopy(for: reference) == nil)
        await second.release(next)
        await first.retire()
        await second.retire()
    }

    @Test func admissionBoundsAggregateBytesAndTransferCount() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = HostFileDiskBudget(root: root, workingSetBytes: 8, diskHeadroomBytes: 0, availableCapacity: { _ in 100 })
        try budget.prepare()
        let first = UUID(), second = UUID(), third = UUID()
        try budget.begin(first)
        try budget.admit(5, for: first)
        try budget.begin(second)
        #expect(throws: HostFileError.busy) { try budget.begin(third) }
        #expect(throws: HostFileError.busy) { try budget.admit(4, for: second) }
        budget.release(first)
        try budget.begin(third)
        try budget.admit(4, for: second)
        budget.release(second)
        budget.release(third)
    }

    @Test func admissionChecksAvailableDiskSpace() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = HostFileDiskBudget(root: root, workingSetBytes: 100, diskHeadroomBytes: 4, availableCapacity: { _ in 10 })
        try budget.prepare()
        let id = UUID()
        try budget.begin(id)
        #expect(throws: HostFileError.insufficientStorage) { try budget.admit(7, for: id) }
        budget.release(id)
    }

    private struct Fixture: Sendable {
        let root: URL
        let hostID: UUID
        let downloader: Downloader
        let store: HostFileStore

        init(steps: [Downloader.Step], cacheBytes: Int64) throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            hostID = UUID()
            downloader = Downloader(steps: steps)
            let budget = HostFileDiskBudget(root: root, workingSetBytes: 1024, diskHeadroomBytes: 0,
                                           availableCapacity: { _ in 10_000 })
            store = HostFileStore(hostID: hostID, connectionID: String(repeating: "a", count: 64), downloader: downloader, budget: budget, cacheBytes: cacheBytes)
        }

        func reference(_ name: String) throws -> HostFileReference {
            try HostFileReference(hostID: hostID, path: "/tmp/" + name)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private actor Signal {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if signalled { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func signal() {
            signalled = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private actor Downloader: GatewayFileDownloading {
        enum Step: Sendable {
            case file(Data, String)
            case unchanged(Data, String)
            case failure(HostFileError)
            case suspended(Signal)
            case late(Signal, Signal)
        }

        private var steps: [Step]
        private(set) var sources: [GatewayFileDownloadSource] = []
        private(set) var revisions: [String?] = []
        private(set) var directories: [URL] = []

        init(steps: [Step]) { self.steps = steps }

        func download(source: GatewayFileDownloadSource, knownRevision: String?, to directory: URL,
                      progress: @escaping @Sendable (HostFileProgress) -> Void,
                      admit: @escaping @Sendable (Int64) throws -> Void) async throws -> GatewayFileDownload {
            let path: String
            switch source {
            case .file(let value, _): path = value
            case .visual(let reference): path = "/different/store/" + reference.digest + ".html"
            }
            sources.append(source)
            revisions.append(knownRevision)
            directories.append(directory)
            guard !steps.isEmpty else { throw HostFileError.invalidResponse }
            let step = steps.removeFirst()
            switch step {
            case .file(let data, let revision):
                return try write(data, revision: revision, path: path, directory: directory, admit: admit)
            case .unchanged(let data, let revision):
                return .unchanged(metadata(data, revision: revision, path: path))
            case .failure(let error): throw error
            case .suspended(let started):
                try Data("partial".utf8).write(to: directory.appending(path: "partial"))
                await started.signal()
                try await Task.sleep(for: .seconds(86_400))
                throw HostFileError.interrupted
            case .late(let started, let finish):
                let result = try write(Data("late".utf8), revision: "late", path: path, directory: directory, admit: admit)
                await started.signal()
                await finish.wait()
                return result
            }
        }

        private func write(_ data: Data, revision: String, path: String, directory: URL,
                           admit: @Sendable (Int64) throws -> Void) throws -> GatewayFileDownload {
            let metadata = metadata(data, revision: revision, path: path)
            try admit(metadata.bytes)
            let url = directory.appendingPathComponent(metadata.name, isDirectory: false)
            try data.write(to: url)
            return .downloaded(metadata, url)
        }

        private func metadata(_ data: Data, revision: String, path: String) -> HostFileMetadata {
            HostFileMetadata(path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                             bytes: Int64(data.count), modifiedAt: 1, revision: revision)
        }
    }
}
