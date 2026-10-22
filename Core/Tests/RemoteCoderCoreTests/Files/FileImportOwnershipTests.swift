import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct FileImportOwnershipTests {
    @Test func stagingAndUploadKeepOneCancellationHandleAndRejectDuplicateRetries() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        fixture.imports.add([fixture.borrowedSource], to: draft)
        await fixture.gateway.waitFor(.starts, 1)
        let file = try #require(draft.attachments.first?.file)
        fixture.imports.retry(.file(file), in: draft)
        #expect(await fixture.gateway.starts == 1)
        #expect(fixture.continuation.begins == 2)
        await fixture.imports.retire()
        #expect(await fixture.gateway.cancellations == 1)
        #expect(draft.attachments.first?.file?.uploaded == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(fixture.staging.url(for: file)).path))
        await fixture.gateway.reportProgress(confirmed: 0, sent: 5)
        await Task.yield()
        #expect(fixture.imports.uploads.isEmpty)
    }

    @Test func completedUploadBelongsToTheCapturedDraftAndIsSavedBeforeStagingRemoval() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let original = try #require(await fixture.drafts.draft(for: .newChatFixture))
        fixture.imports.add([fixture.borrowedSource], to: original)
        await fixture.gateway.waitFor(.starts, 1)
        let staged = try #require(original.attachments.first?.file)
        let other = try #require(await fixture.drafts.draft(for: .thread("another-thread")))
        await fixture.gateway.finishAll()
        let stagedURL = try #require(fixture.staging.url(for: staged))
        #expect(await waitUntil {
            original.attachments.first?.file?.uploaded != nil && !FileManager.default.fileExists(atPath: stagedURL.path)
        })
        #expect(other.attachments.isEmpty)
        let reopened = ComposerDraftStore(directory: fixture.root.appending(path: "drafts"))
        #expect(await reopened.draft(for: .newChatFixture)?.attachments.first?.file?.uploaded != nil)
    }

    @Test func cancelledRemovalCannotPublishAndItsLocalFileIsCleanedAfterTheTaskEnds() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        fixture.imports.add([fixture.borrowedSource], to: draft)
        await fixture.gateway.waitFor(.starts, 1)
        let file = try #require(draft.attachments.first?.file)
        fixture.imports.remove(.file(file))
        fixture.drafts.setAttachments([], in: draft)
        await fixture.drafts.flush()
        await fixture.gateway.waitFor(.discards, 1)
        #expect(await fixture.gateway.discarded == [file.id])
        await fixture.imports.retire()
        #expect(draft.attachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(fixture.staging.url(for: file)).path))
        #expect(await fixture.gateway.cancellations == 1)
    }

    @Test func stagingContinuesWhileUploadsStayWithinTheirBudget() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        fixture.imports.add(Array(repeating: fixture.borrowedSource, count: 5), to: draft)
        await fixture.gateway.waitFor(.starts, 4)
        #expect(await waitUntil { draft.attachments.count == 5 && !fixture.imports.isStaging(draftID: draft.id) })
        #expect(await fixture.gateway.starts == 4)
        await fixture.gateway.finishAll()
        await fixture.gateway.waitFor(.starts, 5)
        await fixture.imports.retire()
        #expect(await fixture.gateway.cancellations == 1)
    }

    @Test func ownedFilesMoveIntoStagingWhileBorrowedFilesAreCopied() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        let owned = try DeferredImportFile.scratchFile(named: "photo.jpg", containing: Data("jpeg".utf8))
        fixture.imports.add([.inOwnDirectory { owned }, fixture.borrowedSource], to: draft)
        await fixture.gateway.waitFor(.starts, 2)
        let staged = draft.attachments.compactMap(\.file)
        #expect(staged.map(\.name) == ["photo.jpg", "sample.txt"])
        #expect(try Data(contentsOf: try #require(fixture.staging.url(for: staged[0]))) == Data("jpeg".utf8))
        #expect(!FileManager.default.fileExists(atPath: owned.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: try #require(fixture.staging.url(for: staged[1]))) == Data("sample".utf8))
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test func filesKeepTheirSelectionOrderWhenALaterOneIsReadyFirst() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        let first = try DeferredImportFile.scratchFile(named: "first.txt", containing: Data("first".utf8))
        let second = try DeferredImportFile.scratchFile(named: "second.txt", containing: Data("second".utf8))
        let (released, release) = AsyncStream<Void>.makeStream()
        fixture.imports.add([
            .inOwnDirectory { for await _ in released { break }; return first },
            .inOwnDirectory { second },
        ], to: draft)
        #expect(await waitUntil { draft.attachments.count == 1 })
        release.yield()
        #expect(await waitUntil { draft.attachments.count == 2 })
        #expect(draft.attachments.compactMap(\.file).map(\.name) == ["first.txt", "second.txt"])
    }

    @Test func savedInlineImagesUploadOnceAsFilesInTheirPlaces() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        let images = ["first", "second"].map { name in
            CodexImageAttachment(id: UUID(), data: Data(name.utf8), format: .jpeg, pixelSize: CodexImagePixelSize(width: 1, height: 1))
        }
        fixture.drafts.setAttachments(images.map { ComposerAttachment(id: $0.id, content: .legacyImage($0)) }, in: draft)
        let interrupted = fixture.staging.directory.appending(path: images[0].id.uuidString)
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: interrupted.appending(path: images[0].fileName))
        fixture.imports.resume(in: draft)
        fixture.imports.resume(in: draft)
        await fixture.gateway.waitFor(.starts, 2)
        let staged = draft.attachments.compactMap(\.file)
        #expect(staged.map(\.id) == images.map(\.id))
        #expect(staged.map(\.name) == images.map(\.fileName))
        for (file, image) in zip(staged, images) {
            #expect(try Data(contentsOf: try #require(fixture.staging.url(for: file))) == image.data)
        }
        await fixture.gateway.finishAll()
        #expect(await waitUntil { draft.attachments.allSatisfy(\.isReadyToSend) })
        #expect(await fixture.gateway.starts == 2)
        #expect(fixture.continuation.begins == 0)
    }

    @Test func interruptedUploadWaitsWithItsProgressAndContinuesTheSameUploadAfterANetworkChange() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        fixture.imports.add([fixture.borrowedSource], to: draft)
        await fixture.gateway.waitFor(.starts, 1)
        let file = try #require(draft.attachments.first?.file)
        await fixture.gateway.reportProgress(confirmed: 0, sent: 3)
        #expect(await waitUntil { fixture.imports.uploads[file.id] == .uploading(fraction: 0.5) })
        await fixture.gateway.interruptAll()
        #expect(await waitUntil { fixture.imports.uploads[file.id] == .waiting(fraction: 0.5) })
        await fixture.gateway.waitFor(.subscriptions, 1)
        await fixture.gateway.changeNetworkPath()
        await fixture.gateway.waitFor(.starts, 2)
        let attempts = await fixture.gateway.uploads
        #expect(attempts[0].id == file.id)
        #expect(attempts[1] == attempts[0])
        await fixture.gateway.finishAll()
        #expect(await waitUntil { draft.attachments.first?.file?.uploaded != nil })
        #expect(fixture.imports.uploads[file.id] == nil)
    }

    @Test func uploadThatStopsAdvancingKeepsWaitingForTheNetwork() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        fixture.imports.add([fixture.borrowedSource], to: draft)
        await fixture.gateway.waitFor(.starts, 1)
        let file = try #require(draft.attachments.first?.file)
        for attempt in 1...6 {
            await fixture.gateway.interruptAll()
            #expect(await waitUntil { fixture.imports.uploads[file.id] == .waiting(fraction: 0) })
            await fixture.gateway.waitFor(.subscriptions, attempt)
            await fixture.gateway.changeNetworkPath()
            await fixture.gateway.waitFor(.starts, attempt + 1)
        }
        await fixture.gateway.interruptAll()
        #expect(await waitUntil { fixture.imports.uploads[file.id] == .waiting(fraction: 0) })
        await fixture.gateway.waitFor(.subscriptions, 7)
        await fixture.gateway.changeNetworkPath()
        await fixture.gateway.waitFor(.starts, 8)
    }

    @Test func pausedUploadIgnoresNetworkChangesUntilTheAppIsActive() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        fixture.imports.add([fixture.borrowedSource], to: draft)
        await fixture.gateway.waitFor(.starts, 1)
        let file = try #require(draft.attachments.first?.file)
        fixture.imports.pauseUntilActive()
        #expect(fixture.imports.uploads[file.id] == .waiting(fraction: 0))
        #expect(await waitUntil { await fixture.gateway.cancellations == 1 })
        await fixture.gateway.waitFor(.subscriptions, 1)
        await fixture.gateway.changeNetworkPath()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fixture.gateway.starts == 1)
        fixture.imports.resumeWaiting()
        await fixture.gateway.waitFor(.starts, 2)
        await fixture.gateway.finishAll()
        #expect(await waitUntil { draft.attachments.first?.file?.uploaded != nil })
    }

    @Test func fileStagedWhilePausedUploadsOnceTheAppIsActive() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        let source = try DeferredImportFile.scratchFile(named: "late.txt", containing: Data("late".utf8))
        let (released, release) = AsyncStream<Void>.makeStream()
        fixture.imports.add([.inOwnDirectory { for await _ in released { break }; return source }], to: draft)
        fixture.imports.pauseUntilActive()
        release.yield()
        #expect(await waitUntil { draft.attachments.count == 1 && !fixture.imports.isStaging(draftID: draft.id) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fixture.gateway.starts == 0)
        fixture.imports.resumeWaiting()
        await fixture.gateway.waitFor(.starts, 1)
    }

    @Test func deletedDraftReleasesItsRunningUploadAndAFileStillStaging() async throws {
        let fixture = try Fixture()
        defer { await fixture.close() }
        let draft = try #require(await fixture.drafts.draft(for: .newChatFixture))
        fixture.imports.add([fixture.borrowedSource], to: draft)
        await fixture.gateway.waitFor(.starts, 1)
        let uploading = try #require(draft.attachments.first?.file)
        let late = try DeferredImportFile.scratchFile(named: "late.txt", containing: Data("late".utf8))
        let (released, release) = AsyncStream<Void>.makeStream()
        fixture.imports.add([.inOwnDirectory { for await _ in released { break }; return late }], to: draft)
        #expect(fixture.imports.isStaging(draftID: draft.id))
        draft.isDiscarded = true
        fixture.imports.release(draft)
        release.yield()
        await fixture.gateway.waitFor(.discards, 1)
        #expect(await fixture.gateway.discarded == [uploading.id])
        #expect(await waitUntil {
            let left = try? FileManager.default.contentsOfDirectory(atPath: fixture.staging.directory.path)
            return await fixture.gateway.cancellations == 1 && (left ?? []).isEmpty && fixture.imports.transfer.files == 0
        })
        #expect(await fixture.gateway.starts == 1)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let source: URL
        let drafts: ComposerDraftStore
        let staging: UploadStaging
        let gateway = UploadGate()
        let continuation = RecordingContinuation()
        let imports: FileAttachmentImports

        init() throws {
            root = URL.temporaryDirectory.appending(path: "file-import-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            source = root.appending(path: "sample.txt")
            try Data("sample".utf8).write(to: source)
            drafts = ComposerDraftStore(directory: root.appending(path: "drafts"))
            staging = UploadStaging(directory: root.appending(path: "staging"))
            imports = FileAttachmentImports(host: GatewayHostConfiguration(id: UUID(), name: "Test",
                hostname: "127.0.0.1", port: 1, authToken: "test"), drafts: drafts, staging: staging,
                client: gateway, continuation: continuation)
        }

        var borrowedSource: DeferredImportFile {
            let source = source
            return .borrowed { source }
        }

        func close() async {
            await imports.retire()
            await drafts.flush()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor
private final class RecordingContinuation: UploadContinuation {
    private(set) var begins = 0

    func begin(for uploads: FileAttachmentImports) { begins += 1 }
    func progressChanged(in uploads: FileAttachmentImports) {}
}

private actor UploadGate: ResumableFileUploading {
    enum Counter { case starts, subscriptions, discards }
    private enum Outcome { case finish, interrupt }

    private(set) var uploads: [GatewayUpload] = []
    private(set) var cancellations = 0
    private(set) var discarded: [UUID] = []
    private var subscriptions = 0
    private var running: [Int: AsyncStream<Outcome>.Continuation] = [:]
    private var paths: [AsyncStream<Void>.Continuation] = []
    private var progress: (@Sendable (GatewayUploadProgress) -> Void)?
    private var waiters: [(Counter, Int, CheckedContinuation<Void, Never>)] = []

    var starts: Int { uploads.count }

    func waitFor(_ counter: Counter, _ count: Int) async {
        if value(of: counter) >= count { return }
        await withCheckedContinuation { waiters.append((counter, count, $0)) }
    }

    func upload(_ upload: GatewayUpload, to host: GatewayHostConfiguration,
                progress: @escaping @Sendable (GatewayUploadProgress) -> Void) async throws -> UploadedFile {
        let attempt = uploads.count
        let (outcomes, deliver) = AsyncStream<Outcome>.makeStream(bufferingPolicy: .bufferingNewest(1))
        running[attempt] = deliver
        self.progress = progress
        uploads.append(upload)
        notifyWaiters()
        defer { running[attempt] = nil }
        var outcome: Outcome?
        for await delivered in outcomes { outcome = delivered; break }
        guard let outcome, !Task.isCancelled else { cancellations += 1; throw CancellationError() }
        switch outcome {
        case .finish: return UploadedFile(path: "/test/uploads/\(upload.name)", bytes: upload.byteCount, sha256: upload.sha256)
        case .interrupt: throw GatewayUploadError.interrupted("connection lost")
        }
    }

    func discard(_ id: UUID, on host: GatewayHostConfiguration) {
        discarded.append(id)
        notifyWaiters()
    }

    func networkPathChanges() -> AsyncStream<Void> {
        let (changes, change) = AsyncStream<Void>.makeStream()
        paths.append(change)
        subscriptions += 1
        notifyWaiters()
        return changes
    }

    func finishAll() { deliver(.finish) }
    func interruptAll() { deliver(.interrupt) }
    func changeNetworkPath() { for path in paths { path.yield() } }
    func reportProgress(confirmed: Int64, sent: Int64) { progress?(GatewayUploadProgress(confirmed: confirmed, sent: sent)) }

    private func deliver(_ outcome: Outcome) {
        for release in running.values { release.yield(outcome); release.finish() }
    }

    private func value(of counter: Counter) -> Int {
        switch counter {
        case .starts: starts
        case .subscriptions: subscriptions
        case .discards: discarded.count
        }
    }

    private func notifyWaiters() {
        let satisfied = waiters.filter { value(of: $0.0) >= $0.1 }
        waiters.removeAll { value(of: $0.0) >= $0.1 }
        satisfied.forEach { $0.2.resume() }
    }
}
