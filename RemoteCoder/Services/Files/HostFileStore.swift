import CryptoKit
import Foundation
import OSLog
import Synchronization

actor HostFileStore {
    private enum Acquisition {
        case file(HostFileReference, String?)
        case visual(HTMLVisualReference)

        var source: GatewayFileDownloadSource {
            switch self {
            case .file(let reference, let directory): .file(path: reference.path, containingDirectory: directory)
            case .visual(let reference): .visual(reference)
            }
        }

        func reference(hostID: UUID, metadata: HostFileMetadata) throws -> HostFileReference {
            switch self {
            case .file(let reference, _): return reference
            case .visual:
                let reference = try HostFileReference(hostID: hostID, path: metadata.path)
                guard reference.path == metadata.path else { throw HostFileError.invalidResponse }
                return reference
            }
        }
    }

    private struct Entry {
        let id: UUID
        let directory: URL
        let metadata: HostFileMetadata
        let url: URL
        let downloadedAt: Date
        var lastAccess: Date
        var holders: Set<UUID>
    }

    private let hostID: UUID
    private let connectionID: String
    private var prepared = false
    private let downloader: any GatewayFileDownloading
    private let budget: HostFileDiskBudget
    private let directory: URL
    private let cacheBytes: Int64
    private let retirement = Mutex(false)
    private let logger = Logger(subsystem: "RemoteCoder", category: "HostFiles")
    private var entries: [UUID: Entry] = [:]
    private var latest: [String: UUID] = [:]
    private var leases: [UUID: UUID] = [:]
    private var transfers: [UUID: Task<GatewayFileDownload, any Error>] = [:]
    private let pathAdmission = HostFilePathAdmission()

    init(host: GatewayHostConfiguration, routes: GatewayRoutes) {
        hostID = host.id
        connectionID = Self.connectionIdentity(host)
        downloader = GatewayFileDownloadClient(host: host, routes: routes)
        budget = .shared
        directory = HostFileDiskBudget.shared.directory
            .appending(path: host.id.uuidString, directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        cacheBytes = HostFileLimits.unheldCacheBytes
    }

    init(hostID: UUID, connectionID: String, downloader: any GatewayFileDownloading, budget: HostFileDiskBudget, cacheBytes: Int64) {
        self.hostID = hostID
        self.connectionID = connectionID
        self.downloader = downloader
        self.budget = budget
        directory = budget.directory.appending(path: hostID.uuidString, directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        self.cacheBytes = cacheBytes
    }

    nonisolated func beginRetirement() {
        retirement.withLock { $0 = true }
    }

    func open(reference: HostFileReference, containingDirectory: String?,
              progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease {
        try validate(reference)
        return try await open(acquisition: .file(reference, containingDirectory), progress: progress)
    }

    func openVisual(reference: HTMLVisualReference,
                    progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease {
        #if RC_PERF_HARNESS
        if AppStorageScope.isOfflineReplay {
            PerformanceReplayHTTP.omitVisual()
            throw URLError(.resourceUnavailable)
        }
        #endif
        return try await open(acquisition: .visual(reference), progress: progress)
    }

    private func open(acquisition: Acquisition,
                      progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease {
        try validate()
        let source = acquisition.source
        try await pathAdmission.acquire(source.key)
        let lease: HostFileLease
        do {
            lease = try await openAcquired(acquisition: acquisition, progress: progress)
        } catch {
            await pathAdmission.release(source.key)
            throw error
        }
        await pathAdmission.release(source.key)
        do { try validate() }
        catch { release(lease); throw error }
        return lease
    }

    private func openAcquired(acquisition: Acquisition,
                              progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease {
        try validate()
        let source = acquisition.source
        try prepare()
        let operationID = UUID()
        try budget.begin(operationID)
        let operationDirectory = directory.appending(path: operationID.uuidString, directoryHint: .isDirectory)
        var published = false
        let candidateID: UUID?
        switch source {
        case .file(let path, _): candidateID = usableEntry(for: path)
        case .visual: candidateID = nil
        }
        if let candidateID { entries[candidateID]?.holders.insert(operationID) }
        defer {
            transfers.removeValue(forKey: operationID)
            if let candidateID { entries[candidateID]?.holders.remove(operationID) }
            if !published { removeTransfer(operationID, directory: operationDirectory) }
            trimCache()
        }
        let originalDirectory = operationDirectory.appending(path: "original", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let revision = candidateID.flatMap { entries[$0]?.metadata.revision }
        let downloader = self.downloader
        let budget = self.budget
        let transfer = Task {
            try await downloader.download(source: source, knownRevision: revision, to: originalDirectory,
                                          progress: progress, admit: {
                                              guard $0 <= source.maximumBytes else { throw HostFileError.tooLarge }
                                              try budget.admit($0, for: operationID)
                                          })
        }
        transfers[operationID] = transfer
        let result = try await withTaskCancellationHandler {
            try await transfer.value
        } onCancel: {
            transfer.cancel()
        }
        try validate()
        switch result {
        case .unchanged(let metadata):
            guard metadata.bytes <= source.maximumBytes else { throw HostFileError.tooLarge }
            guard let candidateID, let candidate = entries[candidateID], candidate.metadata == metadata else {
                throw HostFileError.invalidResponse
            }
            return acquire(candidateID, reference: try acquisition.reference(hostID: hostID, metadata: metadata))
        case .downloaded(let metadata, let url):
            try source.validate(metadata)
            let reference = try acquisition.reference(hostID: hostID, metadata: metadata)
            guard metadata.bytes <= source.maximumBytes else { throw HostFileError.tooLarge }
            guard url == originalDirectory.appendingPathComponent(metadata.name, isDirectory: false),
                  let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(bytes) == metadata.bytes else { throw HostFileError.invalidResponse }
            try budget.admit(metadata.bytes, for: operationID)
            try validate()
            let now = Date()
            try budget.commit(HostFileCacheRecord(id: operationID, hostID: hostID, connectionID: connectionID,
                                                   metadata: metadata, downloadedAt: now, lastAccess: now),
                              at: operationDirectory)
            try validate()
            entries[operationID] = Entry(id: operationID, directory: operationDirectory, metadata: metadata, url: url,
                                         downloadedAt: now, lastAccess: now, holders: [])
            latest[metadata.path] = operationID
            published = true
            return acquire(operationID, reference: reference)
        }
    }

    func cachedCopy(for reference: HostFileReference) throws -> HostFileLease? {
        try validate(reference)
        try prepare()
        guard let id = usableEntry(for: reference.path) else { return nil }
        return acquire(id, reference: reference)
    }

    func release(_ lease: HostFileLease) {
        guard lease.reference.hostID == hostID, let entryID = leases.removeValue(forKey: lease.id) else { return }
        entries[entryID]?.holders.remove(lease.id)
        trimCache()
    }

    func retire() async {
        beginRetirement()
        do { try prepare() }
        catch { logger.error("Could not load retiring file-cache state: \(error.localizedDescription, privacy: .public)") }
        let pending = Array(transfers.values)
        for transfer in pending { transfer.cancel() }
        for transfer in pending { _ = await transfer.result }
        trimCache()
    }

    private static func connectionIdentity(_ host: GatewayHostConfiguration) -> String {
        var hash = SHA256()
        for value in [host.hostname, String(host.port), host.transport.rawValue, host.authToken] {
            hash.update(data: Data("\(value.utf8.count):".utf8))
            hash.update(data: Data(value.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func prepare() throws {
        guard !prepared else { return }
        try budget.prepare()
        for cached in budget.claimCached(hostID: hostID, connectionID: connectionID).sorted(by: {
            $0.record.downloadedAt < $1.record.downloadedAt
        }) {
            let record = cached.record
            entries[record.id] = Entry(id: record.id, directory: cached.directory, metadata: record.metadata,
                                       url: cached.url, downloadedAt: record.downloadedAt,
                                       lastAccess: record.lastAccess, holders: [])
            latest[record.metadata.path] = record.id
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        prepared = true
        trimCache()
    }

    private func validate(_ reference: HostFileReference) throws {
        guard reference.hostID == hostID else { throw HostFileError.wrongHost }
        try validate()
    }

    private func validate() throws {
        try Task.checkCancellation()
        guard !retirement.withLock({ $0 }) else { throw HostFileError.retired }
    }

    private func usableEntry(for path: String) -> UUID? {
        guard let id = latest[path], let entry = entries[id] else { return nil }
        guard budget.pin(id) else {
            _ = removeEntry(entry)
            return nil
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value == entry.metadata.bytes else {
                latest.removeValue(forKey: path)
                if entry.holders.isEmpty { _ = removeEntry(entry) }
                return nil
            }
            return id
        } catch {
            latest.removeValue(forKey: path)
            if entry.holders.isEmpty { _ = removeEntry(entry) }
            return nil
        }
    }

    private func acquire(_ id: UUID, reference: HostFileReference) -> HostFileLease {
        guard var entry = entries[id] else { preconditionFailure("A file acquisition must reference a retained entry.") }
        let leaseID = UUID()
        entry.holders.insert(leaseID)
        entry.lastAccess = Date()
        entries[id] = entry
        leases[leaseID] = id
        return HostFileLease(id: leaseID, reference: reference, metadata: entry.metadata,
                             url: entry.url, downloadedAt: entry.downloadedAt)
    }

    private func trimCache() {
        let retired = retirement.withLock { $0 }
        for entry in entries.values where !budget.contains(entry.id) && entry.holders.isEmpty { _ = removeEntry(entry) }
        let unheld = entries.values.filter { $0.holders.isEmpty }.sorted { $0.lastAccess < $1.lastAccess }
        var bytes = unheld.reduce(Int64(0)) { $0 + $1.metadata.bytes }
        var count = unheld.count
        for entry in unheld {
            if retired || latest[entry.metadata.path] != entry.id || entry.metadata.bytes > cacheBytes
                || bytes > cacheBytes || count > HostFileLimits.maximumCacheEntries {
                if removeEntry(entry) {
                    bytes -= entry.metadata.bytes
                    count -= 1
                }
            } else {
                budget.cache(entry.id)
            }
        }
        if retired, entries.isEmpty, transfers.isEmpty {
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { return }
            catch { logger.error("Could not remove a retired file-cache directory: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func removeEntry(_ entry: Entry) -> Bool {
        guard removeTransfer(entry.id, directory: entry.directory) else { return false }
        entries.removeValue(forKey: entry.id)
        if latest[entry.metadata.path] == entry.id { latest.removeValue(forKey: entry.metadata.path) }
        return true
    }

    @discardableResult
    private func removeTransfer(_ id: UUID, directory: URL) -> Bool {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {
            budget.release(id)
            return true
        } catch {
            logger.error("Could not remove temporary file data: \(error.localizedDescription, privacy: .public)")
            return false
        }
        budget.release(id)
        return true
    }
}
