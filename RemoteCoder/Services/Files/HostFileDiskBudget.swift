import Foundation
import OSLog
import Synchronization

struct HostFileCacheRecord: Codable, Sendable {
    let id: UUID
    let hostID: UUID
    let connectionID: String
    let metadata: HostFileMetadata
    let downloadedAt: Date
    var lastAccess: Date
}

struct HostFileCachedEntry: Sendable {
    let record: HostFileCacheRecord
    let directory: URL

    var url: URL { directory.appending(path: "original", directoryHint: .isDirectory)
        .appendingPathComponent(record.metadata.name, isDirectory: false) }
}

final class HostFileDiskBudget: Sendable {
    static let shared = HostFileDiskBudget(
        root: AppStorageScope.current.caches.appending(path: "RemoteCoder/RemoteFiles", directoryHint: .isDirectory),
        workingSetBytes: HostFileLimits.workingSetBytes,
        diskHeadroomBytes: HostFileLimits.diskHeadroomBytes,
        availableCapacity: { directory in
            guard let bytes = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage else { throw HostFileError.insufficientStorage }
            return bytes
        }
    )

    let directory: URL
    private let workingSetBytes: Int64
    private let diskHeadroomBytes: Int64
    private let availableCapacity: @Sendable (URL) throws -> Int64
    private let state = Mutex(State())
    private let logger = Logger(subsystem: "RemoteCoder", category: "HostFileDiskBudget")

    private struct Reservation {
        var bytes: Int64 = 0
        var transferring = true
        var unheld = false
        var claimed = true
        var cached: HostFileCachedEntry?
    }

    private struct State {
        var prepared = false
        var reservations: [UUID: Reservation] = [:]
    }

    init(root: URL, workingSetBytes: Int64, diskHeadroomBytes: Int64,
         availableCapacity: @escaping @Sendable (URL) throws -> Int64) {
        directory = root
        self.workingSetBytes = workingSetBytes
        self.diskHeadroomBytes = diskHeadroomBytes
        self.availableCapacity = availableCapacity
    }

    func prepare() throws {
        try state.withLock { state in
            guard !state.prepared else { return }
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            for host in try subdirectories(directory) {
                for generation in try subdirectories(host) {
                    for entryDirectory in try subdirectories(generation) {
                        do {
                            let entry = try restore(entryDirectory, host: host)
                            state.reservations[entry.record.id] = Reservation(
                                bytes: entry.record.metadata.bytes, transferring: false, unheld: true,
                                claimed: false, cached: entry)
                            trim(&state)
                        } catch {
                            try manager.removeItem(at: entryDirectory)
                        }
                    }
                    if try manager.contentsOfDirectory(atPath: generation.path).isEmpty { try manager.removeItem(at: generation) }
                }
                if try manager.contentsOfDirectory(atPath: host.path).isEmpty { try manager.removeItem(at: host) }
            }
            state.prepared = true
        }
    }

    func claimCached(hostID: UUID, connectionID: String) -> [HostFileCachedEntry] {
        state.withLock { state in
            var result: [HostFileCachedEntry] = []
            for (id, reservation) in state.reservations {
                guard let cached = reservation.cached, cached.record.hostID == hostID,
                      !reservation.claimed, reservation.unheld else { continue }
                guard cached.record.connectionID == connectionID else {
                    _ = evict(id, from: &state)
                    continue
                }
                state.reservations[id]?.claimed = true
                result.append(cached)
            }
            return result
        }
    }

    func begin(_ id: UUID) throws {
        try state.withLock { state in
            guard state.reservations.values.filter(\.transferring).count < HostFileLimits.maximumTransfers,
                  state.reservations.count < 1024 else { throw HostFileError.busy }
            guard try availableCapacity(directory) >= diskHeadroomBytes else {
                throw HostFileError.insufficientStorage
            }
            state.reservations[id] = Reservation()
        }
    }

    func admit(_ bytes: Int64, for id: UUID) throws {
        guard bytes >= 0, bytes <= HostFileLimits.maximumFileBytes else { throw HostFileError.tooLarge }
        try state.withLock { state in
            guard let current = state.reservations[id] else { throw CancellationError() }
            guard current.bytes != bytes else { return }
            for candidate in evictionOrder(state) {
                let otherBytes = state.reservations.filter { $0.key != id }.values.reduce(Int64(0)) { $0 + $1.bytes }
                if otherBytes <= workingSetBytes - bytes { break }
                _ = evict(candidate, from: &state)
            }
            let others = state.reservations.filter { $0.key != id }.map(\.value)
            guard others.reduce(Int64(0), { $0 + $1.bytes }) <= workingSetBytes - bytes else {
                throw HostFileError.busy
            }
            let inFlightBytes = others.filter(\.transferring).reduce(Int64(0)) { $0 + $1.bytes }
            let required = bytes + inFlightBytes + diskHeadroomBytes
            if try availableCapacity(directory) < required {
                for candidate in evictionOrder(state) { _ = evict(candidate, from: &state) }
            }
            guard try availableCapacity(directory) >= required else { throw HostFileError.insufficientStorage }
            state.reservations[id]?.bytes = bytes
        }
    }

    func commit(_ record: HostFileCacheRecord, at directory: URL) throws {
        try state.withLock { state in
            guard var reservation = state.reservations[record.id] else { throw CancellationError() }
            try write(record, at: directory)
            reservation.transferring = false
            reservation.cached = HostFileCachedEntry(record: record, directory: directory)
            state.reservations[record.id] = reservation
        }
    }

    func pin(_ id: UUID) -> Bool {
        state.withLock { state in
            guard state.reservations[id] != nil else { return false }
            state.reservations[id]?.unheld = false
            return true
        }
    }

    func cache(_ id: UUID) {
        state.withLock { state in
            guard var reservation = state.reservations[id], !reservation.unheld, let cached = reservation.cached else { return }
            var record = cached.record
            record.lastAccess = Date()
            do { try write(record, at: cached.directory) }
            catch { logger.error("Could not update file-cache recency: \(error.localizedDescription, privacy: .public)") }
            reservation.cached = HostFileCachedEntry(record: record, directory: cached.directory)
            reservation.unheld = true
            state.reservations[id] = reservation
            trim(&state)
        }
    }

    func contains(_ id: UUID) -> Bool { state.withLock { $0.reservations[id] != nil } }

    func release(_ id: UUID) { state.withLock { _ = $0.reservations.removeValue(forKey: id) } }

    private func trim(_ state: inout State) {
        var count = state.reservations.values.filter(\.unheld).count
        var bytes = state.reservations.values.filter(\.unheld).reduce(Int64(0)) { $0 + $1.bytes }
        for id in evictionOrder(state) {
            guard let reservation = state.reservations[id] else { continue }
            if bytes <= min(HostFileLimits.unheldCacheBytes, workingSetBytes), count <= HostFileLimits.maximumCacheEntries { break }
            if evict(id, from: &state) { bytes -= reservation.bytes; count -= 1 }
        }
    }

    private func evictionOrder(_ state: State) -> [UUID] {
        state.reservations.filter { $0.value.unheld }.sorted {
            ($0.value.cached?.record.lastAccess ?? .distantPast) < ($1.value.cached?.record.lastAccess ?? .distantPast)
        }.map(\.key)
    }

    private func evict(_ id: UUID, from state: inout State) -> Bool {
        guard let reservation = state.reservations[id], reservation.unheld, let cached = reservation.cached else { return false }
        do { try FileManager.default.removeItem(at: cached.directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {
            state.reservations.removeValue(forKey: id)
            return true
        } catch {
            logger.error("Could not evict cached file data: \(error.localizedDescription, privacy: .public)")
            return false
        }
        state.reservations.removeValue(forKey: id)
        return true
    }

    private func write(_ record: HostFileCacheRecord, at directory: URL) throws {
        let url = directory.appending(path: "record.json")
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: url.path)
    }

    private func subdirectories(_ parent: URL) throws -> [URL] {
        let manager = FileManager.default
        return try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      UUID(uuidString: url.lastPathComponent) != nil else {
                    try manager.removeItem(at: url)
                    return false
                }
                return true
            }
    }

    private func restore(_ directory: URL, host: URL) throws -> HostFileCachedEntry {
        let recordURL = directory.appending(path: "record.json")
        let values = try recordURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard let size = values.fileSize, size <= 32_768, values.isRegularFile == true,
              values.isSymbolicLink != true else { throw HostFileError.invalidResponse }
        let record = try JSONDecoder().decode(HostFileCacheRecord.self, from: Data(contentsOf: recordURL))
        guard record.id.uuidString == directory.lastPathComponent, record.hostID.uuidString == host.lastPathComponent,
              record.connectionID.count == 64,
              record.connectionID.allSatisfy({ $0.isHexDigit }),
              record.downloadedAt.timeIntervalSince1970.isFinite, record.lastAccess.timeIntervalSince1970.isFinite,
              try HostFileReference(hostID: record.hostID, path: record.metadata.path).path == record.metadata.path else {
            throw HostFileError.invalidResponse
        }
        try record.metadata.validate(path: record.metadata.path)
        let entry = HostFileCachedEntry(record: record, directory: directory)
        let original = try entry.url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let file = try entry.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard original.isDirectory == true, original.isSymbolicLink != true,
              file.isRegularFile == true, file.isSymbolicLink != true,
              file.fileSize.map(Int64.init) == record.metadata.bytes else { throw HostFileError.invalidResponse }
        return entry
    }
}
