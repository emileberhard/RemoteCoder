import Foundation
import Observation

/// Owns a picked file from staging through acknowledgement. Staging and
/// uploading have separate slots, so the next file is prepared while earlier
/// ones upload. A cancelled transfer keeps its slot until it actually
/// finishes; retries cannot replace its handle. An interrupted upload waits
/// without a slot and continues from the gateway's offset after a backoff, a
/// network change or the app becoming active; once backoffs stop advancing
/// it, only the network or the app wakes it.
@MainActor @Observable
final class FileAttachmentImports {
    enum UploadState: Equatable, Sendable {
        case uploading(fraction: Double)
        case waiting(fraction: Double)
        case failed(String)
    }

    struct Transfer: Equatable {
        var files = 0
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var hasFailures = false
    }

    private enum Source {
        case deferred(DeferredImportFile)
        case staged(ComposerFileAttachment)
    }

    private enum Phase { case staging, uploading }

    private struct Import {
        let id: UUID
        let generation = UUID()
        let draft: ComposerDraft
        let source: Source
        var onStaged: ((AttachmentStagingResult) -> Void)? = nil
        var onUploadFailure: (() -> Void)? = nil

        var phase: Phase {
            if case .staged = source { .uploading } else { .staging }
        }

        var byteCount: Int64? {
            if case .staged(let file) = source { file.byteCount } else { nil }
        }

        func restarted() -> Import {
            Import(id: id, draft: draft, source: source, onStaged: onStaged, onUploadFailure: onUploadFailure)
        }
    }

    private struct Running {
        let item: Import
        let task: Task<Void, Never>
    }

    private struct Waiting {
        let item: Import
        var timer: Task<Void, Never>?
        var isDue = false
    }

    private struct Retry {
        var attempts = 0
        var confirmed: Int64 = -1
    }

    private(set) var uploads: [UUID: UploadState] = [:]
    private(set) var errorMessage: String?
    private var stagingDrafts: [UUID: UUID] = [:]
    @ObservationIgnored private let host: GatewayHostConfiguration
    @ObservationIgnored private let drafts: ComposerDraftStore
    @ObservationIgnored private let staging: UploadStaging
    @ObservationIgnored private let client: any ResumableFileUploading
    @ObservationIgnored private let continuation: any UploadContinuation
    @ObservationIgnored private var pending: [Import] = []
    @ObservationIgnored private var running: [UUID: Running] = [:]
    @ObservationIgnored private var waiting: [UUID: Waiting] = [:]
    @ObservationIgnored private var retries: [UUID: Retry] = [:]
    @ObservationIgnored private var prepared: [UUID: GatewayUpload] = [:]
    @ObservationIgnored private var sentBytes: [UUID: Int64] = [:]
    @ObservationIgnored private var batchFinished: [UUID: Int64] = [:]
    @ObservationIgnored private var discards: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var networkWatch: Task<Void, Never>?
    @ObservationIgnored private var admissions: [UUID: Int] = [:]
    @ObservationIgnored private var nextAdmission = 0
    @ObservationIgnored private var isPausedUntilActive = false
    @ObservationIgnored private var isRetired = false
    private static let stagingConcurrency = 2
    private static let uploadConcurrency = 4
    private static let timedRetriesWithoutProgress = 6

    init(host: GatewayHostConfiguration, drafts: ComposerDraftStore, staging: UploadStaging,
         client: any ResumableFileUploading, continuation: any UploadContinuation) {
        self.host = host
        self.drafts = drafts
        self.staging = staging
        self.client = client
        self.continuation = continuation
    }

    func isStaging(draftID: UUID) -> Bool { pendingCount(for: draftID) > 0 }

    func stagedCopy(of file: ComposerFileAttachment) -> URL? { staging.url(for: file) }

    func pendingCount(for draftID: UUID) -> Int {
        stagingDrafts.values.count { $0 == draftID }
    }

    var transfer: Transfer {
        var inFlight: [UUID: Import] = [:]
        for item in pending + running.values.map(\.item)
        where inFlight[item.id]?.byteCount == nil && batchFinished[item.id] == nil {
            inFlight[item.id] = item
        }
        if !isPausedUntilActive {
            for entry in waiting.values where inFlight[entry.item.id] == nil { inFlight[entry.item.id] = entry.item }
        }
        let finished = batchFinished.values.reduce(0, +)
        var transfer = Transfer(completedBytes: finished, totalBytes: finished,
                                hasFailures: uploads.values.contains { if case .failed = $0 { true } else { false } })
        for item in inFlight.values {
            transfer.files += 1
            guard let byteCount = item.byteCount else { continue }
            transfer.totalBytes += byteCount
            transfer.completedBytes += min(sentBytes[item.id] ?? 0, byteCount)
        }
        return transfer
    }

    func add(_ files: [DeferredImportFile], to draft: ComposerDraft, onStaged: ((AttachmentStagingResult) -> Void)? = nil, onUploadFailure: (() -> Void)? = nil) {
        guard !isRetired, drafts.acceptsInput else {
            for _ in files { onStaged?(.cancelled) }
            return
        }
        for file in files {
            let item = Import(id: UUID(), draft: draft, source: .deferred(file), onStaged: onStaged, onUploadFailure: onUploadFailure)
            stagingDrafts[item.id] = draft.id
            admissions[item.id] = nextAdmission
            nextAdmission += 1
            pending.append(item)
        }
        startPending()
        continuation.begin(for: self)
    }

    func retry(_ attachment: ComposerAttachment, in draft: ComposerDraft, onUploadFailure: (() -> Void)? = nil) {
        if waiting[attachment.id] != nil {
            retries[attachment.id] = nil
            makeDue(attachment.id)
        } else {
            retries[attachment.id] = nil
            enqueue(attachment, in: draft, onUploadFailure: onUploadFailure)
        }
        continuation.begin(for: self)
    }

    func resume(in draft: ComposerDraft) {
        for attachment in draft.attachments { enqueue(attachment, in: draft) }
    }

    func resumeWaiting() {
        isPausedUntilActive = false
        wakeWaiting()
    }

    func pauseUntilActive() {
        guard !isRetired else { return }
        isPausedUntilActive = true
        for (id, entry) in waiting {
            entry.timer?.cancel()
            waiting[id]?.timer = nil
        }
        for active in running.values where active.item.phase == .uploading {
            waiting[active.item.id] = Waiting(item: active.item)
            uploads[active.item.id] = .waiting(fraction: fraction(of: active.item.id))
            active.task.cancel()
        }
        startPending()
    }

    private func enqueue(_ attachment: ComposerAttachment, in draft: ComposerDraft, onUploadFailure: (() -> Void)? = nil) {
        guard !isRetired, drafts.acceptsInput, running[attachment.id] == nil, waiting[attachment.id] == nil,
              !pending.contains(where: { $0.id == attachment.id }) else { return }
        switch attachment.content {
        case .file(let file) where file.uploaded == nil:
            pending.append(Import(id: file.id, draft: draft, source: .staged(file), onUploadFailure: onUploadFailure))
        case .legacyImage(let image):
            stagingDrafts[image.id] = draft.id
            pending.append(Import(id: image.id, draft: draft, source: .deferred(.inOwnDirectory { try await Self.write(image) }),
                                  onUploadFailure: onUploadFailure))
        case .file, .text:
            return
        }
        uploads[attachment.id] = .uploading(fraction: fraction(of: attachment.id))
        startPending()
    }

    @concurrent
    private static func write(_ image: CodexImageAttachment) async throws -> URL {
        try DeferredImportFile.scratchFile(named: image.fileName, containing: image.data)
    }

    func remove(_ attachment: ComposerAttachment) {
        drop(attachment.id, discarding: attachment.file.map { $0.uploaded == nil } ?? false)
        startPending()
    }

    func release(_ draft: ComposerDraft) {
        let imports = pending + running.values.map(\.item) + waiting.values.map(\.item)
        let files = draft.attachments.compactMap(\.file)
        let ids = Set(imports.filter { $0.draft === draft }.map(\.id) + files.map(\.id))
        for id in ids {
            drop(id, discarding: files.first { $0.id == id }.map { $0.uploaded == nil } ?? false)
        }
        startPending()
    }

    private func drop(_ id: UUID, discarding: Bool) {
        for item in pending where item.id == id { item.onStaged?(.cancelled) }
        pending.removeAll { $0.id == id }
        waiting.removeValue(forKey: id)?.timer?.cancel()
        uploads[id] = nil
        stagingDrafts[id] = nil
        retries[id] = nil
        prepared[id] = nil
        sentBytes[id] = nil
        if let active = running[id] { active.task.cancel() }
        else { staging.remove(id: id) }
        if discarding { discard(id) }
    }

    func dismissError() {
        errorMessage = nil
    }

    func quiesce() -> [Task<Void, Never>] {
        for item in pending { item.onStaged?(.cancelled) }
        pending.removeAll()
        stagingDrafts.removeAll()
        admissions.removeAll()
        stopWaiting()
        let tasks = running.values.map(\.task) + discards.values
        for task in tasks { task.cancel() }
        batchFinished.removeAll()
        continuation.progressChanged(in: self)
        return tasks
    }

    func beginRetirement() {
        guard !isRetired else { return }
        isRetired = true
        for item in pending { item.onStaged?(.cancelled) }
        pending.removeAll()
        stagingDrafts.removeAll()
        admissions.removeAll()
        uploads.removeAll()
        stopWaiting()
        for active in running.values { active.task.cancel() }
        for discard in discards.values { discard.cancel() }
        batchFinished.removeAll()
        continuation.progressChanged(in: self)
    }

    func retire() async {
        beginRetirement()
        for active in running.values { await active.task.value }
        for discard in discards.values { await discard.value }
    }

    private func stopWaiting() {
        for entry in waiting.values { entry.timer?.cancel() }
        for id in waiting.keys where uploads[id] != nil { uploads[id] = nil }
        waiting.removeAll()
        retries.removeAll()
        networkWatch?.cancel()
        networkWatch = nil
    }

    private func startPending() {
        if stagingDrafts.isEmpty { admissions.removeAll() }
        if !isRetired, !isPausedUntilActive {
            for (id, entry) in waiting where entry.isDue && running[id] == nil {
                waiting[id] = nil
                pending.append(entry.item.restarted())
                uploads[id] = .uploading(fraction: fraction(of: id))
            }
        }
        while !isRetired, drafts.acceptsInput, let index = pending.firstIndex(where: hasCapacity(for:)) {
            let item = pending.remove(at: index)
            let task = Task<Void, Never> { [weak self] in await self?.perform(item) }
            running[item.id] = Running(item: item, task: task)
        }
        watchNetworkWhileWaiting()
        if pending.isEmpty, running.isEmpty, waiting.isEmpty { batchFinished.removeAll() }
        continuation.progressChanged(in: self)
    }

    private func hasCapacity(for item: Import) -> Bool {
        guard running[item.id] == nil else { return false }
        switch item.phase {
        case .staging:
            return running.values.count { $0.item.phase == .staging } < Self.stagingConcurrency
        case .uploading:
            return !isPausedUntilActive && running.values.count { $0.item.phase == .uploading } < Self.uploadConcurrency
        }
    }

    private func owns(_ item: Import) -> Bool {
        !isRetired && drafts.acceptsInput && !Task.isCancelled && running[item.id]?.item.generation == item.generation
    }

    private func perform(_ item: Import) async {
        defer {
            if running[item.id]?.item.generation == item.generation {
                running[item.id] = nil
                stagingDrafts[item.id] = nil
                // A removed chip, a deleted draft or a cancelled staging attempt has
                // no durable record to recover. A staged attachment survives host retirement.
                if item.draft.isDiscarded || item.draft.attachments.first(where: { $0.id == item.id })?.file == nil {
                    staging.remove(id: item.id)
                }
                startPending()
            }
        }
        switch item.source {
        case .deferred: await stage(item)
        case .staged(let file): await upload(file, for: item)
        }
    }

    private func stage(_ item: Import) async {
        var result = AttachmentStagingResult.cancelled
        defer { item.onStaged?(result) }
        do {
            let staged = try await prepare(item)
            guard owns(item) else { return }
            let file = ComposerFileAttachment(id: item.id, name: staged.fileName, byteCount: staged.byteCount,
                placement: .staged(fileName: staged.fileName))
            drafts.setAttachments(placing(file, in: item.draft.attachments), in: item.draft)
            guard await drafts.flush() else {
                throw UploadStaging.Failure(message: drafts.errorMessage ?? "Could not save the file attachment.")
            }
            guard owns(item) else { return }
            stagingDrafts[item.id] = nil
            result = .accepted
            pending.append(Import(id: item.id, draft: item.draft, source: .staged(file), onUploadFailure: item.onUploadFailure))
        } catch {
            guard owns(item) else { return }
            result = .failed
            report(error, for: item)
        }
    }

    private func placing(_ file: ComposerFileAttachment, in attachments: [ComposerAttachment]) -> [ComposerAttachment] {
        var attachments = attachments
        if let index = attachments.firstIndex(where: { $0.id == file.id }) {
            attachments[index] = .file(file)
        } else {
            let admission = admissions[file.id] ?? .max
            let later = attachments.firstIndex { (admissions[$0.id] ?? .min) > admission }
            attachments.insert(.file(file), at: later ?? attachments.endIndex)
        }
        return attachments
    }

    private func prepare(_ item: Import) async throws -> UploadStaging.StagedFile {
        guard case .deferred(let file) = item.source else {
            preconditionFailure("A staged attachment does not need preparation.")
        }
        let url = try await file.load()
        switch file.ownership {
        case .borrowed:
            return try await staging.prepare(url, id: item.id)
        case .owned:
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return try await staging.adopt(url, id: item.id)
        }
    }

    private func upload(_ file: ComposerFileAttachment, for item: Import) async {
        do {
            guard owns(item), item.draft.attachments.contains(where: { $0.id == item.id }) else { return }
            guard let url = staging.url(for: file), FileManager.default.fileExists(atPath: url.path) else {
                throw UploadStaging.Failure(message: "The local copy is gone. Remove the file and attach it again.")
            }
            uploads[item.id] = .uploading(fraction: fraction(of: item.id))
            let upload = try await gatewayUpload(for: file, at: url)
            guard owns(item) else { return }
            let id = item.id
            let generation = item.generation
            let stored = try await client.upload(upload, to: host) { [weak self] progress in
                Task { @MainActor [weak self] in self?.progressed(id, generation: generation, progress) }
            }
            guard owns(item), item.draft.attachments.contains(where: { $0.id == item.id }) else { return }
            let attachments = item.draft.attachments.map { attachment -> ComposerAttachment in
                guard attachment.id == item.id, var updated = attachment.file else { return attachment }
                updated.placement = .uploaded(stored)
                return .file(updated)
            }
            drafts.setAttachments(attachments, in: item.draft)
            uploads[item.id] = nil
            retries[item.id] = nil
            prepared[item.id] = nil
            sentBytes[item.id] = nil
            batchFinished[item.id] = file.byteCount
            // Keep the only recoverable copy until the new placement is saved.
            if await drafts.flush() { staging.remove(id: item.id) }
        } catch GatewayUploadError.interrupted {
            guard owns(item) else { return }
            wait(item)
        } catch {
            guard owns(item) else { return }
            report(error, for: item)
        }
    }

    private func gatewayUpload(for file: ComposerFileAttachment, at url: URL) async throws -> GatewayUpload {
        if let cached = prepared[file.id], cached.file == url, cached.byteCount == file.byteCount { return cached }
        let upload = try await GatewayUpload.prepare(id: file.id, file: url, name: file.name)
        prepared[file.id] = upload
        return upload
    }

    private func progressed(_ id: UUID, generation: UUID, _ progress: GatewayUploadProgress) {
        guard !isRetired, let active = running[id], active.item.generation == generation,
              case .uploading? = uploads[id], let byteCount = active.item.byteCount, byteCount > 0 else { return }
        if progress.confirmed > retries[id, default: Retry()].confirmed {
            retries[id] = Retry(attempts: 0, confirmed: progress.confirmed)
        }
        sentBytes[id] = progress.sent
        uploads[id] = .uploading(fraction: Double(progress.sent) / Double(byteCount))
        continuation.progressChanged(in: self)
    }

    private func wait(_ item: Import) {
        var retry = retries[item.id, default: Retry()]
        retry.attempts += 1
        retries[item.id] = retry
        uploads[item.id] = .waiting(fraction: fraction(of: item.id))
        waiting[item.id] = Waiting(item: item)
        guard !isPausedUntilActive, retry.attempts <= Self.timedRetriesWithoutProgress else { return }
        let id = item.id
        let delay = Self.backoff(after: retry.attempts)
        waiting[id]?.timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.makeDue(id)
        }
    }

    private static func backoff(after attempts: Int) -> Duration {
        let seconds = min(60, Double(1 << min(attempts, 6)))
        return .seconds(seconds * Double.random(in: 0.75...1.25))
    }

    private func makeDue(_ id: UUID) {
        guard waiting[id] != nil else { return }
        waiting[id]?.timer?.cancel()
        waiting[id]?.timer = nil
        waiting[id]?.isDue = true
        startPending()
    }

    private func wakeWaiting() {
        guard !isPausedUntilActive else { return }
        for id in waiting.keys {
            waiting[id]?.timer?.cancel()
            waiting[id]?.timer = nil
            waiting[id]?.isDue = true
        }
        startPending()
    }

    private func watchNetworkWhileWaiting() {
        guard !waiting.isEmpty, !isRetired else {
            networkWatch?.cancel()
            networkWatch = nil
            return
        }
        guard networkWatch == nil else { return }
        let client = client
        networkWatch = Task { [weak self] in
            for await _ in await client.networkPathChanges() {
                self?.wakeWaiting()
            }
        }
    }

    private func fraction(of id: UUID) -> Double {
        switch uploads[id] {
        case .uploading(let fraction)?, .waiting(let fraction)?: fraction
        case .failed?, nil: 0
        }
    }

    private func discard(_ id: UUID) {
        guard !isRetired, discards[id] == nil else { return }
        let client = client
        let host = host
        discards[id] = Task { [weak self] in
            try? await client.discard(id, on: host)
            self?.discards[id] = nil
        }
    }

    private func report(_ error: Error, for item: Import) {
        if item.draft.attachments.contains(where: { $0.id == item.id }) {
            uploads[item.id] = .failed(error.localizedDescription)
            item.onUploadFailure?()
        } else {
            errorMessage = error.localizedDescription
        }
    }
}

struct DeferredImportFile {
    fileprivate enum Ownership { case borrowed, owned }

    let load: @MainActor () async throws -> URL
    fileprivate let ownership: Ownership

    static func borrowed(_ load: @escaping @MainActor () async throws -> URL) -> DeferredImportFile {
        DeferredImportFile(load: load, ownership: .borrowed)
    }

    static func inOwnDirectory(_ load: @escaping @MainActor () async throws -> URL) -> DeferredImportFile {
        DeferredImportFile(load: load, ownership: .owned)
    }

    static func scratchFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "composer-import-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    static func scratchFile(named name: String, containing data: Data) throws -> URL {
        try scratchFile(named: name) { try data.write(to: $0) }
    }

    static func scratchCopy(of file: URL) throws -> URL {
        try scratchFile(named: file.lastPathComponent) { try FileManager.default.copyItem(at: file, to: $0) }
    }

    private static func scratchFile(named name: String, writing write: (URL) throws -> Void) throws -> URL {
        let file = try scratchFile(named: name)
        do {
            try write(file)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            throw error
        }
    }
}
