import Foundation
import Observation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

protocol HostFileAccess: Sendable {
    func open(reference: HostFileReference, containingDirectory: String?, progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease
    func openVisual(reference: HTMLVisualReference, progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease
    func cachedCopy(for reference: HostFileReference) async throws -> HostFileLease?
    func release(_ lease: HostFileLease) async
}

extension HostFileStore: HostFileAccess {}

struct HostFileTransition: Sendable {
    typealias Frame = @MainActor @Sendable () -> CGRect
    let frame: Frame
    let image: DecodedImage
}

extension HostFileReference {
    var diagnosticType: String {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        return switch pathExtension {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp",
             "pdf", "md", "markdown", "mdown", "txt", "json", "html", "htm", "svg": pathExtension
        case "": "none"
        default: "other"
        }
    }
}

extension Error {
    var diagnosticReason: String {
        switch self as any Error {
        case HostFileError.server: "server"
        case let error as HostFileError: String(describing: error)
        case let error as HostImagePreviewError: String(describing: error)
        case let error as URLError: "url.\(error.code.rawValue)"
        case let error as CocoaError: "cocoa.\(error.code.rawValue)"
        default: "other"
        }
    }
}

extension ContinuousClock.Instant {
    var elapsedMilliseconds: Int {
        Int((ContinuousClock.now - self) / .milliseconds(1))
    }
}

@MainActor
final class OpenedHostFile {
    let lease: HostFileLease
    let isCachedCopy: Bool
    let transition: HostFileTransition?
    private let access: any HostFileAccess
    var id: UUID { lease.id }

    init(lease: HostFileLease, isCachedCopy: Bool, transition: HostFileTransition?, access: any HostFileAccess) {
        self.lease = lease
        self.isCachedCopy = isCachedCopy
        self.transition = transition
        self.access = access
    }

    func openResource(_ reference: HostFileReference, containingDirectory: String) async throws -> OpenedHostFile {
        let lease = try await access.open(reference: reference, containingDirectory: containingDirectory, progress: { _ in })
        let resource = OpenedHostFile(lease: lease, isCachedCopy: false, transition: nil, access: access)
        try Task.checkCancellation()
        return resource
    }

    deinit {
        let access = access
        let lease = lease
        Task { await access.release(lease) }
    }
}

@MainActor
final class OpenedEmbeddedFile {
    let id = UUID()
    let staged: StagedEmbeddedFile
    let transition: HostFileTransition?

    init(staged: StagedEmbeddedFile, transition: HostFileTransition?) {
        self.staged = staged
        self.transition = transition
    }

    deinit {
        let staged = staged
        Task.detached(priority: .utility) { staged.discard() }
    }
}

@MainActor
enum OpenedFile {
    case host(OpenedHostFile)
    case embedded(OpenedEmbeddedFile)

    var id: UUID {
        switch self {
        case .host(let file): file.id
        case .embedded(let file): file.id
        }
    }

    var url: URL {
        switch self {
        case .host(let file): file.lease.url
        case .embedded(let file): file.staged.url
        }
    }

    var name: String {
        switch self {
        case .host(let file): file.lease.metadata.name
        case .embedded(let file): file.staged.url.lastPathComponent
        }
    }

    var bytes: Int64 {
        switch self {
        case .host(let file): file.lease.metadata.bytes
        case .embedded(let file): file.staged.bytes
        }
    }

    var transition: HostFileTransition? {
        switch self {
        case .host(let file): file.transition
        case .embedded(let file): file.transition
        }
    }

    var host: OpenedHostFile? {
        if case .host(let file) = self { return file }
        return nil
    }
}

struct HostFileOrigin: Equatable, Sendable {
    let hostID: UUID
    let conversationID: UUID
    let transcriptID: String
    let workingDirectory: String?
    let hostName: String
    let presentationScope: UUID?
}

struct HostFileFailure {
    enum Reason: Equatable {
        case invalidLink, transfer, preparation
    }

    let reason: Reason
    let reference: HostFileReference?
    let message: String
    let cached: OpenedHostFile?
}

struct HostFileReaderContent: Sendable {
    let sourceChunks: [String]
    let blocks: [RenderedMarkdownBlock]
}

enum HostFilePreviewPolicy {
    static let markdownByteLimit: Int64 = 2 * 1_024 * 1_024

    static func isMarkdown(_ name: String) -> Bool {
        ["md", "markdown", "mdown"].contains((name as NSString).pathExtension.lowercased())
    }

    private static let activeContentTypes: [UTType] = [.html, .svg, .webArchive, .javaScript]
        + ["public.xhtml", "org.ietf.mhtml"].compactMap(UTType.init)

    static func permitsQuickLook(_ name: String) -> Bool {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return true }
        return !activeContentTypes.contains { type.conforms(to: $0) }
    }
}

enum HostFileReaderWorkBudget {
    private static let maxUnits = 4_000
    private static let maxLines = 32_768
    private static let maxSyntaxCharacters = 16_384
    private static let fencedSourceByteLimit = 131_072
    private static let cancellationCheckInterval = 4_096

    static func admits(_ source: String) throws -> Bool {
        var lines = 1
        var units = 0
        var syntax = 0
        var first: UInt32?
        var firstIsDigit = false
        var pipes = 0
        var inProse = false
        var fenceCharacter: UInt32?
        var fenceRun = 0
        var scanned = 0
        var previousWasCarriageReturn = false
        let bytes = source.utf8.count

        func finishLine() -> Bool {
            if let first {
                let structural: Bool
                switch first {
                case 35, 42, 43, 45, 61, 62, 95, 96, 126: structural = true
                default: structural = firstIsDigit || pipes > 0
                }
                if structural { units += 1 + pipes }
                else if !inProse { units += 1 }
                inProse = !structural
            } else {
                inProse = false
            }
            first = nil
            firstIsDigit = false
            pipes = 0
            return units <= maxUnits
        }

        try Task.checkCancellation()
        for scalar in source.unicodeScalars {
            scanned += 1
            if scanned.isMultiple(of: cancellationCheckInterval) { try Task.checkCancellation() }
            let value = scalar.value
            if value == 10, previousWasCarriageReturn {
                previousWasCarriageReturn = false
                continue
            }
            previousWasCarriageReturn = value == 13
            switch value {
            case 10, 11, 12, 13, 133, 8_232, 8_233:
                guard finishLine() else { return false }
                lines += 1
                guard lines <= maxLines else { return false }
            default:
                if first == nil, !scalar.properties.isWhitespace {
                    first = value
                    firstIsDigit = scalar.properties.generalCategory == .decimalNumber
                }
            }
            if value == 124 {
                pipes += 1
                guard units + pipes <= maxUnits else { return false }
            }
            switch value {
            case 33, 34, 35, 39, 42, 60, 62, 91, 92, 93, 95, 96, 124, 126:
                syntax += 1
                guard syntax <= maxSyntaxCharacters else { return false }
            default:
                break
            }
            if value == 96 || value == 126 {
                fenceRun = fenceCharacter == value ? fenceRun + 1 : 1
                fenceCharacter = value
                if fenceRun >= 3, bytes > fencedSourceByteLimit { return false }
            } else {
                fenceRun = 0
                fenceCharacter = nil
            }
        }
        try Task.checkCancellation()
        return finishLine()
    }
}

actor HostFileReader {
    private static let maxRenderedBlocks = 4_000
    private static let sourceChunkLength = 8_192

    private let render: @Sendable (String) throws -> [RenderedMarkdownBlock]

    init(render: @escaping @Sendable (String) throws -> [RenderedMarkdownBlock]) {
        self.render = render
    }

    nonisolated static func renderMarkdown(_ source: String) -> [RenderedMarkdownBlock] {
        var highlighting = SyntaxHighlightCache()
        return MarkdownRendering.parse(source, previous: nil, isStreaming: false,
            highlighting: &highlighting).blocks
    }

    func prepare(url: URL, name: String, bytes: Int64) throws -> HostFileReaderContent? {
        guard HostFilePreviewPolicy.isMarkdown(name), bytes <= HostFilePreviewPolicy.markdownByteLimit else { return nil }
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        guard data.count <= HostFilePreviewPolicy.markdownByteLimit,
              let source = String(data: data, encoding: .utf8) else { return nil }
        guard try HostFileReaderWorkBudget.admits(source) else { return nil }
        let blocks = try render(source)
        try Task.checkCancellation()
        guard blocks.count <= Self.maxRenderedBlocks else { return nil }
        var sourceChunks: [String] = []
        var remainder = source[...]
        while !remainder.isEmpty {
            try Task.checkCancellation()
            let end = remainder.index(remainder.startIndex, offsetBy: Self.sourceChunkLength, limitedBy: remainder.endIndex) ?? remainder.endIndex
            sourceChunks.append(String(remainder[..<end]))
            remainder = remainder[end...]
        }
        return HostFileReaderContent(sourceChunks: sourceChunks, blocks: blocks)
    }
}

struct HostFileSheet: Identifiable {
    enum Content {
        case document(OpenedFile, HostFileReaderContent?)
        case html(OpenedHostFile)
        case failure(HostFileFailure)
    }
    let id = UUID()
    let content: Content
}

@MainActor
@Observable
final class HostFileOpener {
    private(set) var origin: HostFileOrigin?
    private(set) var progress: HostFileProgress?
    private(set) var loadingName: String?
    private(set) var showsProgress = false
    var sheet: HostFileSheet?
    private(set) var quickLook: OpenedFile?
    private(set) var lastDocument: OpenedFile?
    @ObservationIgnored private let access: any HostFileAccess
    @ObservationIgnored private let canPreview: @MainActor (URL) -> Bool
    @ObservationIgnored private let logger = Logger(subsystem: "RemoteCoder", category: "HostFiles")
    @ObservationIgnored private let reader = HostFileReader(render: HostFileReader.renderMarkdown)
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private(set) var operation: Task<Void, Never>?
    @ObservationIgnored private var progressDelay: Task<Void, Never>?
    @ObservationIgnored private var activeWork: Task<Void, Never>?
    @ObservationIgnored private var loadingReference: HostFileReference?
    private enum PendingWork {
        case download(HostFileReference, UUID, HostFileTransition?)
        case embedded(EmbeddedFileRequest, UUID, HostFileTransition.Frame?)
        case cached(OpenedHostFile, UUID)
    }
    @ObservationIgnored private var pendingWork: PendingWork?
    private enum PendingAction {
        case open(HostFileReference, HostFileOrigin, HostFileTransition?)
        case embedded(EmbeddedFileRequest, HostFileOrigin, HostFileTransition.Frame?)
        case cached(OpenedHostFile)
        case failure(HostFileFailure, HostFileOrigin)
    }
    @ObservationIgnored private var pendingAction: PendingAction?
    @ObservationIgnored private var awaitsDismissal = false

    init(access: any HostFileAccess, canPreview: @escaping @MainActor (URL) -> Bool) {
        self.access = access
        self.canPreview = canPreview
    }

    deinit {
        operation?.cancel()
        activeWork?.cancel()
        progressDelay?.cancel()
    }

    func open(_ url: URL, origin: HostFileOrigin, relativeTo: String?, transition: HostFileTransition?) -> OpenURLAction.Result {
        do {
            guard let reference = try HostFileReference.resolve(url: url, hostID: origin.hostID, relativeTo: relativeTo) else {
                return .systemAction
            }
            request(reference, origin: origin, transition: transition)
        } catch {
            logger.notice("file link rejected reason=\(error.diagnosticReason, privacy: .public)")
            let failure = HostFileFailure(reason: .invalidLink, reference: nil, message: error.localizedDescription, cached: nil)
            if dismissForNextAction(.failure(failure, origin)) { return .handled }
            invalidate()
            self.origin = origin
            sheet = HostFileSheet(content: .failure(failure))
        }
        return .handled
    }

    func request(_ reference: HostFileReference, origin: HostFileOrigin, transition: HostFileTransition?) {
        guard loadingReference != reference || self.origin != origin else { return }
        if dismissForNextAction(.open(reference, origin, transition)) { return }
        start(reference, origin: origin, transition: transition)
    }

    func open(_ embedded: EmbeddedFileRequest, origin: HostFileOrigin, frame: HostFileTransition.Frame?) {
        if dismissForNextAction(.embedded(embedded, origin, frame)) { return }
        start(embedded, origin: origin, frame: frame)
    }

    func presents(in scope: UUID?) -> Bool {
        origin?.presentationScope == scope
    }

    func leavePresentationScope(_ scope: UUID) {
        guard origin?.presentationScope == scope else { return }
        leaveScreen()
    }

    private func dismissForNextAction(_ action: PendingAction) -> Bool {
        guard sheet != nil || quickLook != nil || awaitsDismissal else { return false }
        pendingAction = action
        awaitsDismissal = true
        sheet = nil
        quickLook = nil
        return true
    }

    func presentationDismissed() {
        if let shown = quickLook ?? lastDocument { logger.notice("file presentation dismissed file=\(Self.tag(shown.id), privacy: .public)") }
        quickLook = nil
        awaitsDismissal = false
        let next = pendingAction
        pendingAction = nil
        switch next {
        case .open(let reference, let origin, let transition):
            start(reference, origin: origin, transition: transition)
        case .embedded(let embedded, let origin, let frame):
            start(embedded, origin: origin, frame: frame)
        case .cached(let file):
            pendingWork = .cached(file, generation)
            runPendingWork()
        case .failure(let failure, let origin):
            invalidate()
            self.origin = origin
            sheet = HostFileSheet(content: .failure(failure))
        case nil:
            break
        }
    }

    func cancelDownload() {
        if let loadingReference {
            logger.notice("file open cancelled operation=\(Self.tag(self.generation), privacy: .public) type=\(loadingReference.diagnosticType, privacy: .public)")
        }
        generation = UUID()
        pendingAction = nil
        pendingWork = nil
        activeWork?.cancel()
        loadingReference = nil
        progressDelay?.cancel()
        progressDelay = nil
        progress = nil
        loadingName = nil
        showsProgress = false
    }

    func invalidate() {
        cancelDownload()
        awaitsDismissal = awaitsDismissal || sheet != nil || quickLook != nil
        sheet = nil
        quickLook = nil
        lastDocument = nil
        origin = nil
    }

    func suspendPresentation() {
        cancelDownload()
        awaitsDismissal = false
        sheet = nil
        quickLook = nil
    }

    func quickLookUnavailable(_ id: UUID) {
        guard quickLook?.id == id else { return }
        logger.notice("quick look unavailable file=\(Self.tag(id), privacy: .public)")
        quickLook = nil
        awaitsDismissal = false
    }

    func leaveScreen() {
        invalidate()
        awaitsDismissal = false
    }

    func showOptions() {
        guard let lastDocument else { return }
        sheet = HostFileSheet(content: .document(lastDocument, nil))
    }

    func useCachedCopy(_ file: OpenedHostFile) {
        if !dismissForNextAction(.cached(file)) {
            pendingWork = .cached(file, generation)
            runPendingWork()
        }
    }

    private func start(_ reference: HostFileReference, origin: HostFileOrigin, transition: HostFileTransition?) {
        let token = begin(origin: origin, name: (reference.path as NSString).lastPathComponent)
        loadingReference = reference
        logger.notice("file open requested operation=\(Self.tag(token), privacy: .public) type=\(reference.diagnosticType, privacy: .public) source=\(transition == nil ? "link" : "image", privacy: .public)")
        pendingWork = .download(reference, token, transition)
        runPendingWork()
    }

    private func start(_ embedded: EmbeddedFileRequest, origin: HostFileOrigin, frame: HostFileTransition.Frame?) {
        let token = begin(origin: origin, name: embedded.suggestedName.isEmpty ? "File" : embedded.suggestedName)
        logger.notice("file open requested operation=\(Self.tag(token), privacy: .public) source=embedded length=\(embedded.dataURL.utf16.count, privacy: .public)")
        pendingWork = .embedded(embedded, token, frame)
        runPendingWork()
    }

    private func begin(origin: HostFileOrigin, name: String) -> UUID {
        invalidate()
        self.origin = origin
        loadingName = name
        let token = generation
        progressDelay = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, generation == token, loadingName != nil else { return }
            showsProgress = true
            AccessibilityNotification.Announcement("Downloading file").post()
        }
        return token
    }

    private func runPendingWork() {
        guard operation == nil else { return }
        operation = Task { [weak self] in
            while let self, let work = self.pendingWork {
                self.pendingWork = nil
                let task = Task { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    switch work {
                    case .download(let reference, let token, let transition):
                        await download(reference, token: token, transition: transition)
                    case .embedded(let embedded, let token, let frame):
                        await stage(embedded, token: token, frame: frame)
                    case .cached(let file, let token):
                        do {
                            let content = try await reader.prepare(url: file.lease.url, name: file.lease.metadata.name,
                                                                   bytes: file.lease.metadata.bytes)
                            guard generation == token, !Task.isCancelled else { return }
                            present(.host(file), content: content, prefersQuickLook: false)
                        } catch {
                            guard generation == token, !Task.isCancelled else { return }
                            finishLoading()
                            sheet = HostFileSheet(content: .failure(HostFileFailure(reason: .preparation,
                                reference: file.lease.reference, message: error.localizedDescription, cached: nil)))
                        }
                    }
                }
                activeWork = task
                await task.value
                activeWork = nil
            }
            self?.operation = nil
        }
    }

    private func download(_ reference: HostFileReference, token: UUID, transition: HostFileTransition?) async {
        let started = ContinuousClock.now
        let lease: HostFileLease
        do {
            lease = try await access.open(reference: reference, containingDirectory: nil) { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.progress = value
                }
            }
        } catch {
            if !(error is CancellationError) {
                logger.error("file open failed operation=\(Self.tag(token), privacy: .public) elapsed=\(started.elapsedMilliseconds, privacy: .public)ms reason=\(error.diagnosticReason, privacy: .public)")
            }
            await showTransferFailure(error, for: reference, token: token)
            return
        }
        logger.notice("file open fetched operation=\(Self.tag(token), privacy: .public) bytes=\(lease.metadata.bytes, privacy: .public) elapsed=\(started.elapsedMilliseconds, privacy: .public)ms")
        guard generation == token, !Task.isCancelled else {
            await access.release(lease)
            return
        }
        let content: HostFileReaderContent?
        do {
            content = try await reader.prepare(url: lease.url, name: lease.metadata.name, bytes: lease.metadata.bytes)
        } catch {
            await access.release(lease)
            guard generation == token, !Task.isCancelled else { return }
            finishLoading()
            sheet = HostFileSheet(content: .failure(HostFileFailure(reason: .preparation,
                reference: reference, message: error.localizedDescription, cached: nil)))
            return
        }
        guard generation == token, !Task.isCancelled else {
            await access.release(lease)
            return
        }
        let file = OpenedHostFile(lease: lease, isCachedCopy: false, transition: transition, access: access)
        present(.host(file), content: content, prefersQuickLook: true)
    }

    private func stage(_ embedded: EmbeddedFileRequest, token: UUID, frame: HostFileTransition.Frame?) async {
        let started = ContinuousClock.now
        let prepared: (staged: StagedEmbeddedFile, content: HostFileReaderContent?, image: DecodedImage?)
        do {
            prepared = try await Self.prepare(embedded, reader: reader, transitionImage: frame != nil)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            logger.error("file open failed operation=\(Self.tag(token), privacy: .public) elapsed=\(started.elapsedMilliseconds, privacy: .public)ms reason=\(error.diagnosticReason, privacy: .public)")
            finishLoading()
            sheet = HostFileSheet(content: .failure(HostFileFailure(reason: .preparation,
                reference: nil, message: error.localizedDescription, cached: nil)))
            return
        }
        let transition: HostFileTransition? = if let frame, let image = prepared.image {
            HostFileTransition(frame: frame, image: image)
        } else { nil }
        let file = OpenedEmbeddedFile(staged: prepared.staged, transition: transition)
        guard generation == token, !Task.isCancelled else { return }
        logger.notice("file open staged operation=\(Self.tag(token), privacy: .public) bytes=\(prepared.staged.bytes, privacy: .public) elapsed=\(started.elapsedMilliseconds, privacy: .public)ms")
        present(.embedded(file), content: prepared.content, prefersQuickLook: true)
    }

    @concurrent
    private static func prepare(_ embedded: EmbeddedFileRequest, reader: HostFileReader, transitionImage: Bool) async throws
        -> (staged: StagedEmbeddedFile, content: HostFileReaderContent?, image: DecodedImage?) {
        let staged = try EmbeddedFile.stage(embedded,
            in: FileManager.default.temporaryDirectory.appending(path: "EmbeddedFiles", directoryHint: .isDirectory))
        do {
            let content = try await reader.prepare(url: staged.url, name: staged.url.lastPathComponent, bytes: staged.bytes)
            let isImage = UTType(filenameExtension: staged.url.pathExtension)?.conforms(to: .image) == true
            let image = transitionImage && isImage
                ? try await ImagePreparation.shared.thumbnail(url: staged.url, maxDimension: HostImagePreviews.maximumPixelSize)
                : nil
            return (staged, content, image)
        } catch {
            staged.discard()
            throw error
        }
    }

    private func showTransferFailure(_ error: any Error, for reference: HostFileReference, token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }
        var message = error.localizedDescription
        let cachedLease: HostFileLease?
        do {
            cachedLease = try await access.cachedCopy(for: reference)
        } catch {
            cachedLease = nil
            message += " The saved copy could not be read: \(error.localizedDescription)"
        }
        guard generation == token, !Task.isCancelled else {
            if let cachedLease { await access.release(cachedLease) }
            return
        }
        let cached = cachedLease.map { OpenedHostFile(lease: $0, isCachedCopy: true, transition: nil, access: access) }
        finishLoading()
        sheet = HostFileSheet(content: .failure(HostFileFailure(reason: .transfer,
            reference: reference, message: message, cached: cached)))
    }

    private func present(_ file: OpenedFile, content: HostFileReaderContent?, prefersQuickLook: Bool) {
        finishLoading()
        lastDocument = file
        if let host = file.host, HostHTMLDocument.admits(host.lease) {
            logger.notice("file presented file=\(Self.tag(file.id), privacy: .public) as=html")
            sheet = HostFileSheet(content: .html(host))
        } else if content == nil, prefersQuickLook, HostFilePreviewPolicy.permitsQuickLook(file.name),
           canPreview(file.url) {
            logger.notice("file presented file=\(Self.tag(file.id), privacy: .public) as=quickLook zoom=\(file.transition != nil, privacy: .public)")
            quickLook = file
        } else {
            logger.notice("file presented file=\(Self.tag(file.id), privacy: .public) as=\(content == nil ? "information" : "reader", privacy: .public)")
            sheet = HostFileSheet(content: .document(file, content))
        }
    }

    private static func tag(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func finishLoading() {
        loadingReference = nil
        progressDelay?.cancel()
        progressDelay = nil
        loadingName = nil
        progress = nil
        showsProgress = false
    }
}
