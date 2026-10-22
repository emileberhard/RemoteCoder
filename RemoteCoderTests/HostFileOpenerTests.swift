import CoreGraphics
import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct HostFileOpenerTests {
    @Test func memoryPressureDropsImagePreviewsWithoutDiscardingPendingResults() async throws {
        let access = ControlledFileAccess()
        let previews = HostImagePreviews(access: access)
        let reference = try HostFileReference(hostID: UUID(), path: "/tmp/pixel.png")
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=="))
        try bytes.write(to: url)
        let lease = HostFileLease(id: UUID(), reference: reference,
            metadata: HostFileMetadata(path: reference.path, name: "pixel.png", bytes: Int64(bytes.count),
                modifiedAt: 1, revision: "1"), url: url, downloadedAt: .now)
        let first = Task { try await previews.preview(reference) }
        await access.waitForOpen(1)
        await access.finish(0, with: .success(lease))
        let image = try await first.value
        #expect(image.pixelSize == CGSize(width: 1, height: 1))
        #expect(previews.cached(reference) != nil)

        previews.releaseReusableCaches()
        #expect(previews.cached(reference) == nil)
        #expect(previews.pixelSize(for: reference) == image.pixelSize)

        let pending = Task { try await previews.preview(reference) }
        await access.waitForOpen(2)
        previews.releaseReusableCaches()
        let pendingLease = HostFileLease(id: UUID(), reference: reference, metadata: lease.metadata,
            url: url, downloadedAt: lease.downloadedAt)
        await access.finish(1, with: .success(pendingLease))
        #expect(try await pending.value.pixelSize == image.pixelSize)
        #expect(previews.cached(reference) == nil)
        await access.waitForRelease(pendingLease.id)
    }

    @Test func cancelledTransferCannotPresentAndReleasesItsLateLease() async throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in false })
        let origin = origin()
        let reference = try HostFileReference(hostID: origin.hostID, path: "/tmp/report.bin")
        opener.request(reference, origin: origin, transition: nil)
        let operation = try #require(opener.operation)
        await access.waitForOpen(1)
        opener.invalidate()
        let lease = lease(reference)
        await access.finish(0, with: .success(lease))
        await operation.value
        await access.waitForRelease(lease.id)
        #expect(opener.sheet == nil)
        #expect(opener.quickLook == nil)
        #expect(opener.lastDocument == nil)
        #expect(opener.origin == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func latestReplacementWaitsForCancelledTransferCleanup() async throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in false })
        let origin = origin()
        let first = try HostFileReference(hostID: origin.hostID, path: "/tmp/first.html")
        let second = try HostFileReference(hostID: origin.hostID, path: "/tmp/second.html")
        let latest = try HostFileReference(hostID: origin.hostID, path: "/tmp/latest.html")
        opener.request(first, origin: origin, transition: nil)
        let worker = try #require(opener.operation)
        await access.waitForOpen(1)
        opener.request(second, origin: origin, transition: nil)
        opener.request(latest, origin: origin, transition: nil)
        let oldLease = lease(first)
        await access.finish(0, with: .success(oldLease))
        await access.waitForOpen(2)
        #expect(await access.references == [first, latest])
        #expect(await access.busyFailures == 0)
        #expect(await access.releasedOnAdmission[1].contains(oldLease.id))
        await access.finish(1, with: .success(lease(latest)))
        await worker.value
        #expect(opener.lastDocument?.host?.lease.reference == latest)
        #expect(opener.quickLook == nil)
        guard case .html(let file) = opener.sheet?.content else {
            Issue.record("Expected the HTML preview")
            return
        }
        #expect(file.lease.reference == latest)
        opener.invalidate()
    }

    @Test func repeatedTapReusesTheActiveDownloadWithoutCancellation() async throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in false })
        let origin = origin()
        let reference = try HostFileReference(hostID: origin.hostID, path: "/tmp/report.html")
        opener.request(reference, origin: origin, transition: nil)
        let worker = try #require(opener.operation)
        await access.waitForOpen(1)
        opener.request(reference, origin: origin, transition: nil)
        opener.request(reference, origin: origin, transition: nil)
        await access.finish(0, with: .success(lease(reference)))
        await worker.value
        #expect(await access.references == [reference])
        #expect(await access.cancelledReferences.isEmpty)
        #expect(await access.busyFailures == 0)
        #expect(opener.lastDocument?.host?.lease.reference == reference)
        opener.invalidate()
    }

    @Test func failedRevalidationRequiresExplicitDatedCachedCopyChoice() async throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in false })
        let origin = origin()
        let reference = try HostFileReference(hostID: origin.hostID, path: "/tmp/report.html")
        let saved = lease(reference)
        await access.setCached(saved)
        opener.request(reference, origin: origin, transition: nil)
        let operation = try #require(opener.operation)
        await access.waitForOpen(1)
        await access.finish(0, with: .failure(HostFileError.unavailable))
        await operation.value
        #expect(opener.lastDocument == nil)
        guard case .failure(let failure) = opener.sheet?.content else {
            Issue.record("Expected the failed revalidation surface")
            return
        }
        let cached = try #require(failure.cached)
        #expect(cached.isCachedCopy)
        #expect(cached.lease.downloadedAt == saved.downloadedAt)
        opener.useCachedCopy(cached)
        #expect(opener.sheet == nil)
        #expect(opener.lastDocument == nil)
        opener.presentationDismissed()
        await opener.operation?.value
        #expect(opener.lastDocument?.host?.isCachedCopy == true)
        #expect(opener.quickLook == nil)
        opener.invalidate()
    }

    @Test func unreadableDownloadedFileSurfacesAPreparationFailure() async throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in false })
        let origin = origin()
        let reference = try HostFileReference(hostID: origin.hostID, path: "/tmp/report.md")
        let unreadable = lease(reference)
        opener.request(reference, origin: origin, transition: nil)
        let operation = try #require(opener.operation)
        await access.waitForOpen(1)
        await access.finish(0, with: .success(unreadable))
        await operation.value
        await access.waitForRelease(unreadable.id)
        guard case .failure(let failure) = opener.sheet?.content else {
            Issue.record("Expected the preparation failure surface")
            return
        }
        #expect(failure.reason == .preparation)
        #expect(failure.reference == reference)
        #expect(opener.lastDocument == nil)
        #expect(opener.quickLook == nil)
        opener.invalidate()
    }

    @Test func backgroundCancellationDropsQueuedPresentation() async throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in false })
        let origin = origin()
        let reference = try HostFileReference(hostID: origin.hostID, path: "/tmp/report.html")
        opener.request(reference, origin: origin, transition: nil)
        let operation = try #require(opener.operation)
        await access.waitForOpen(1)
        await access.finish(0, with: .failure(HostFileError.missing))
        await operation.value
        opener.request(reference, origin: origin, transition: nil)
        opener.cancelDownload()
        opener.presentationDismissed()
        #expect(opener.sheet == nil)
        #expect(opener.loadingName == nil)
        #expect(await access.openCount == 1)
    }

    @Test func leavingScreenDoesNotStrandFutureOpensBehindAnOldDismissal() async throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in false })
        let origin = origin()
        let reference = try HostFileReference(hostID: origin.hostID, path: "/tmp/report.html")
        opener.request(reference, origin: origin, transition: nil)
        let first = try #require(opener.operation)
        await access.waitForOpen(1)
        await access.finish(0, with: .success(lease(reference)))
        await first.value
        #expect(opener.sheet != nil)
        opener.leaveScreen()
        opener.request(reference, origin: origin, transition: nil)
        let second = try #require(opener.operation)
        await access.waitForOpen(2)
        await access.finish(1, with: .success(lease(reference)))
        await second.value
        #expect(opener.sheet != nil)
        opener.invalidate()
    }

    @Test func readerLinksUseRemoteSourceDirectoryAndCapturedHost() async throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in false })
        let origin = origin()
        let url = try #require(URL(string: "../other/My%20Report.html#L12"))
        _ = opener.open(url, origin: origin, relativeTo: "/Users/developer/reports/nested", transition: nil)
        let operation = try #require(opener.operation)
        await access.waitForOpen(1)
        let reference = try #require(await access.references.first)
        #expect(reference.hostID == origin.hostID)
        #expect(reference.path == "/Users/developer/reports/other/My Report.html")
        #expect(reference.lineAnchor == 12)
        opener.invalidate()
        await access.finish(0, with: .failure(CancellationError()))
        await operation.value
    }

    @Test(arguments: ["https://example.com/report.pdf", "mailto:example@example.com", "custom://file"])
    func webLinksAndUnknownSchemesNeverStartFileTransfers(link: String) throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in false })
        _ = opener.open(try #require(URL(string: link)), origin: origin(), relativeTo: "/tmp", transition: nil)
        #expect(opener.operation == nil)
        #expect(opener.sheet == nil)
    }

    @Test func activeContentStaysExportableWithoutQuickLook() {
        for name in ["page.html", "page.XHTML", "page.shtml", "drawing.svg", "page.webarchive", "script.js"] {
            #expect(!HostFilePreviewPolicy.permitsQuickLook(name))
        }
        #expect(HostFilePreviewPolicy.permitsQuickLook("report.pdf"))
        #expect(HostFilePreviewPolicy.permitsQuickLook("report.unfamiliar"))
        #expect(HostFilePreviewPolicy.permitsQuickLook("build.py"))
    }

    @Test(arguments: ["report.html", "report.HTM", "report.xhtml"])
    func htmlUsesItsOwnPreviewAndInformationActionsRemainAvailable(name: String) async throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in true })
        let origin = origin()
        let reference = try HostFileReference(hostID: origin.hostID, path: "/tmp/\(name)")
        opener.request(reference, origin: origin, transition: nil)
        let operation = try #require(opener.operation)
        await access.waitForOpen(1)
        await access.finish(0, with: .success(lease(reference)))
        await operation.value
        guard case .html(let file) = opener.sheet?.content else {
            Issue.record("Expected a rendered HTML presentation")
            return
        }
        #expect(file.lease.reference == reference)
        #expect(opener.quickLook == nil)
        opener.sheet = nil
        opener.presentationDismissed()
        opener.showOptions()
        guard case .document(let exported, nil) = opener.sheet?.content else {
            Issue.record("Expected file information and original-byte export")
            return
        }
        #expect(exported.id == file.id)
        opener.invalidate()
    }

    @Test func largeHTMLUsesTheWebPreview() async throws {
        let access = ControlledFileAccess()
        let opener = HostFileOpener(access: access, canPreview: { _ in true })
        let origin = origin()
        let reference = try HostFileReference(hostID: origin.hostID, path: "/tmp/large.html")
        let small = lease(reference)
        let large = HostFileLease(id: small.id, reference: reference,
            metadata: HostFileMetadata(path: reference.path, name: "large.html", bytes: 9 * 1_024 * 1_024,
                                       modifiedAt: 0, revision: "large"),
            url: small.url, downloadedAt: small.downloadedAt)
        opener.request(reference, origin: origin, transition: nil)
        let operation = try #require(opener.operation)
        await access.waitForOpen(1)
        await access.finish(0, with: .success(large))
        await operation.value
        guard case .html(let file) = opener.sheet?.content else {
            Issue.record("Expected the HTML preview")
            return
        }
        #expect(file.lease.metadata.bytes == 9 * 1_024 * 1_024)
        #expect(opener.quickLook == nil)
        opener.invalidate()
    }

    @Test(arguments: ["headings", "list", "table", "inline", "lines", "fenced", "ordered", "unicodeOrdered", "equals", "underscores"])
    func adversarialReaderInputIsRejectedBeforeRendering(kind: String) async throws {
        let source: String
        switch kind {
        case "headings": source = String(repeating: "# h\n", count: 100_000)
        case "list": source = String(repeating: "- x\n", count: 100_000)
        case "table": source = String(repeating: "| x", count: 100_000) + "|\n| --- |\n"
        case "inline": source = String(repeating: "*a* ", count: 10_000)
        case "lines": source = String(repeating: "\n", count: 100_000)
        case "ordered": source = String(repeating: "1. item\n", count: 5_000)
        case "unicodeOrdered": source = String(repeating: "١. item\n", count: 5_000)
        case "equals": source = String(repeating: "===\n", count: 5_000)
        case "underscores": source = String(repeating: "___\n", count: 5_000)
        default: source = "```swift\n" + String(repeating: "let a = 1\n", count: 20_000) + "```"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(source.utf8)
        try data.write(to: url)
        let reference = try HostFileReference(hostID: UUID(), path: "/tmp/report.md")
        let lease = HostFileLease(id: UUID(), reference: reference,
            metadata: HostFileMetadata(path: reference.path, name: "report.md", bytes: Int64(data.count),
                modifiedAt: 0, revision: "test"), url: url, downloadedAt: Date())
        let reader = HostFileReader { _ in throw ReaderProbeError.unexpectedRender }
        #expect(try await reader.prepare(url: lease.url, name: lease.metadata.name, bytes: lease.metadata.bytes) == nil)
    }

    @Test func readerBudgetAllowsTwoMiBOfPlainProseWithoutDerivedGraphExplosion() throws {
        #expect(try HostFileReaderWorkBudget.admits(String(repeating: "a", count: 2 * 1_024 * 1_024)))
        let wrapped = String(repeating: String(repeating: "a", count: 80) + "\n", count: 25_000)
        #expect(try HostFileReaderWorkBudget.admits(wrapped))
        #expect(try HostFileReaderWorkBudget.admits(wrapped.replacingOccurrences(of: "\n", with: "\r\n")))
    }

    @Test func readerBudgetCountsUnicodeLineSeparators() throws {
        #expect(try !HostFileReaderWorkBudget.admits(String(repeating: "# h\u{2028}", count: 4_001)))
    }

    @Test func embeddedFileOpensInQuickLookAndDiscardsItsCopyOnRelease() async throws {
        let opener = HostFileOpener(access: ControlledFileAccess(), canPreview: { _ in true })
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        opener.open(EmbeddedFileRequest(dataURL: "data:image/png;base64,\(png)", suggestedName: "Chart"),
                    origin: origin(), frame: { CGRect(x: 10, y: 20, width: 30, height: 40) })
        await opener.operation?.value
        let folder: URL
        do {
            let file = try #require(opener.quickLook)
            #expect(file.host == nil)
            #expect(file.name == "Chart.png")
            #expect(try Data(contentsOf: file.url) == Data(base64Encoded: png))
            #expect(file.transition?.frame() == CGRect(x: 10, y: 20, width: 30, height: 40))
            folder = file.url.deletingLastPathComponent()
        }
        opener.invalidate()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: folder.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func undecodableEmbeddedFileReportsAFailure() async throws {
        let opener = HostFileOpener(access: ControlledFileAccess(), canPreview: { _ in true })
        opener.open(EmbeddedFileRequest(dataURL: "data:image/png;base64,%zz", suggestedName: ""), origin: origin(), frame: nil)
        await opener.operation?.value
        guard case .failure(let failure) = opener.sheet?.content else {
            Issue.record("Expected the failure surface")
            return
        }
        #expect(failure.message == EmbeddedFileError.invalid.localizedDescription)
        #expect(opener.quickLook == nil)
    }

    @Test func presentationsBelongToTheScopeThatRequestedThem() async throws {
        let opener = HostFileOpener(access: ControlledFileAccess(), canPreview: { _ in true })
        let sheet = UUID(), other = UUID()
        opener.open(EmbeddedFileRequest(dataURL: "data:text/csv;base64,YSxi", suggestedName: "table"),
                    origin: origin(presentationScope: sheet), frame: nil)
        await opener.operation?.value
        #expect(opener.quickLook?.name == "table.csv")
        #expect(opener.presents(in: sheet))
        #expect(!opener.presents(in: nil))
        opener.leavePresentationScope(other)
        #expect(opener.quickLook != nil)
        opener.leavePresentationScope(sheet)
        #expect(opener.quickLook == nil)
        #expect(opener.lastDocument == nil)
        #expect(opener.presents(in: nil))
    }

    private func origin(presentationScope: UUID? = nil) -> HostFileOrigin {
        HostFileOrigin(hostID: UUID(), conversationID: UUID(),
            transcriptID: "captured-transcript", workingDirectory: "/tmp", hostName: "Mac", presentationScope: presentationScope)
    }

    private func lease(_ reference: HostFileReference) -> HostFileLease {
        HostFileLease(id: UUID(), reference: reference,
            metadata: HostFileMetadata(path: reference.path, name: (reference.path as NSString).lastPathComponent,
                bytes: 123, modifiedAt: 100, revision: "revision"),
            url: URL(fileURLWithPath: "/nonexistent/preview-test/" + (reference.path as NSString).lastPathComponent),
            downloadedAt: Date(timeIntervalSince1970: 200))
    }
}

private actor ControlledFileAccess: HostFileAccess {
    private(set) var references: [HostFileReference] = []
    var openCount: Int { references.count }
    private var opens: [Int: CheckedContinuation<HostFileLease, any Error>] = [:]
    private var openWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var released: Set<UUID> = []
    private var releaseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cached: HostFileLease?
    private var activePaths: Set<String> = []
    private(set) var busyFailures = 0
    private(set) var cancelledReferences: [HostFileReference] = []
    private(set) var releasedOnAdmission: [Set<UUID>] = []

    func openVisual(reference: HTMLVisualReference, progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease {
        throw HostFileError.unavailable
    }

    func open(reference: HostFileReference, containingDirectory: String?, progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease {
        guard activePaths.isEmpty else {
            busyFailures += 1
            throw HostFileError.busy
        }
        activePaths.insert(reference.path)
        defer {
            activePaths.remove(reference.path)
            if Task.isCancelled { cancelledReferences.append(reference) }
        }
        let index = references.count
        references.append(reference)
        releasedOnAdmission.append(released)
        return try await withCheckedThrowingContinuation { continuation in
            opens[index] = continuation
            let ready = openWaiters.filter { $0.0 <= references.count }
            openWaiters.removeAll { $0.0 <= references.count }
            for waiter in ready { waiter.1.resume() }
        }
    }

    func finish(_ index: Int, with result: Result<HostFileLease, any Error>) {
        opens.removeValue(forKey: index)?.resume(with: result)
    }

    func waitForOpen(_ count: Int) async {
        guard references.count < count else { return }
        await withCheckedContinuation { openWaiters.append((count, $0)) }
    }

    func setCached(_ lease: HostFileLease) { cached = lease }
    func cachedCopy(for reference: HostFileReference) -> HostFileLease? { cached }
    func release(_ lease: HostFileLease) {
        released.insert(lease.id)
        releaseWaiters.removeValue(forKey: lease.id)?.resume()
    }
    func waitForRelease(_ id: UUID) async {
        guard !released.contains(id) else { return }
        await withCheckedContinuation { releaseWaiters[id] = $0 }
    }
}

private enum ReaderProbeError: Error {
    case unexpectedRender
}
