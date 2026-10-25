import CryptoKit
import Foundation
import OSLog

nonisolated struct HistoryPageKey: Hashable, Codable, Sendable {
    let hostID: String
    let provider: String
    let threadID: String
    let generation: UInt64
    /// Canonical method and parameters, including cursor, direction, and detail.
    let request: String

    var lineage: HistoryPageKey {
        HistoryPageKey(hostID: hostID, provider: provider, threadID: threadID, generation: 0, request: request)
    }
}

actor HistoryPageCache {
    enum Persistence { case memory, disk }

    private enum Scope: Hashable {
        case host(String)
        case thread(hostID: String, threadID: String)
    }

    nonisolated struct Entry: Sendable {
        let data: Data
        let fetchedAt: Date
        let isFresh: Bool
        let readStartedAt: ContinuousClock.Instant?
    }

    private struct Envelope: Codable {
        let version: Int
        let key: HistoryPageKey
        let fetchedAt: Date
        let data: Data
        var comparisonFingerprint: Data? = nil
    }

    private struct MemoryEntry {
        let data: Data
        let fetchedAt: Date
        var access: UInt64
        let readStartedAt: ContinuousClock.Instant?
    }

    private struct DiskEntry {
        let url: URL
        let bytes: Int
        let fingerprint: Data
        var accessedAt: Date
        var readStartedAt: ContinuousClock.Instant?
    }

    private let directory: URL
    private let memoryBudgetBytes: Int
    private let diskBudgetBytes: Int
    private let freshnessInterval: TimeInterval
    private let logger = Logger(subsystem: "RemoteCoder", category: "HistoryPageCache")
    private var memory: [HistoryPageKey: MemoryEntry] = [:]
    private var disk: [HistoryPageKey: DiskEntry] = [:]
    private var memoryBytes = 0
    private var diskBytes = 0
    private var access: UInt64 = 0
    private var invalidatedKeys: Set<HistoryPageKey> = []
    private var invalidations: [Scope: ContinuousClock.Instant] = [:]
    private var invalidationFloor: ContinuousClock.Instant?
    private var writeOrder: [HistoryPageKey: ContinuousClock.Instant] = [:]
    private var writeOrderFloor: ContinuousClock.Instant?
    private static let writeOrderLimit = 64
    private var loadedDiskIndex = false
    private static let version = 3

    static let shared = HistoryPageCache(directory: HostStorage.live.directory(for: .device)
        .appendingPathComponent("history-pages", isDirectory: true))

    init(
        directory: URL,
        memoryBudgetBytes: Int = 16 * 1_024 * 1_024,
        diskBudgetBytes: Int = 64 * 1_024 * 1_024,
        freshnessInterval: TimeInterval = 300
    ) {
        precondition(memoryBudgetBytes >= 0 && diskBudgetBytes >= 0 && freshnessInterval >= 0)
        self.directory = directory
        self.memoryBudgetBytes = memoryBudgetBytes
        self.diskBudgetBytes = diskBudgetBytes
        self.freshnessInterval = freshnessInterval
    }

    func value(for key: HistoryPageKey, now: Date = Date()) -> Entry? {
        loadDiskIndexIfNeeded()
        if var cached = memory[key] {
            access &+= 1
            cached.access = access
            memory[key] = cached
            touchDisk(key, now: now)
            return entry(data: cached.data, fetchedAt: cached.fetchedAt, now: now, readStartedAt: cached.readStartedAt)
        }
        guard !invalidatedKeys.contains(key), let record = disk[key] else { return nil }
        do {
            let envelope = try PropertyListDecoder().decode(Envelope.self, from: Data(contentsOf: record.url))
            guard envelope.version == Self.version, envelope.key == key else {
                discardDisk(key)
                return nil
            }
            insertMemory(envelope.data, for: key, fetchedAt: envelope.fetchedAt, readStartedAt: record.readStartedAt)
            touchDisk(key, now: now)
            return entry(data: envelope.data, fetchedAt: envelope.fetchedAt, now: now, readStartedAt: record.readStartedAt)
        } catch {
            logger.notice("History page cache read failed; discarding rebuildable entry: \(error.localizedDescription, privacy: .public)")
            discardDisk(key)
            return nil
        }
    }

    /// Call only after a successful response has been decoded and validated.
    func store(_ data: Data, for key: HistoryPageKey, fetchedAt: Date = Date(), startedAt: ContinuousClock.Instant, readStartedAt: ContinuousClock.Instant, persistence: Persistence = .disk, comparisonFingerprint: SHA256.Digest? = nil) throws {
        let cutoff = [invalidationFloor, invalidations[.host(key.hostID)],
            invalidations[.thread(hostID: key.hostID, threadID: key.threadID)]].compactMap { $0 }.max()
        guard cutoff.map({ readStartedAt > $0 }) ?? true else { throw HistoryReadFailure.invalidated }
        loadDiskIndexIfNeeded()
        let latest = [memory[key]?.readStartedAt, disk[key]?.readStartedAt, writeOrder[key], writeOrderFloor].compactMap { $0 }.max()
        guard latest.map({ startedAt >= $0 }) ?? true, !isSuperseded(key) else { return }
        if writeOrder[key] == nil, writeOrder.count >= Self.writeOrderLimit {
            writeOrderFloor = [writeOrderFloor, writeOrder.values.max()].compactMap { $0 }.max()
            writeOrder.removeAll(keepingCapacity: true)
            guard writeOrderFloor.map({ startedAt >= $0 }) ?? true else { return }
        }
        writeOrder[key] = startedAt
        // Huge single items may be displayed, but must not evict the whole cache.
        guard data.count <= memoryBudgetBytes else {
            removeMemory(key)
            discardDisk(key)
            return
        }
        insertMemory(data, for: key, fetchedAt: fetchedAt, readStartedAt: startedAt)
        guard persistence == .disk else {
            discardDisk(key)
            return
        }
        let fingerprint = comparisonFingerprint.map { Data($0) } ?? Data(SHA256.hash(data: data))
        if disk[key]?.fingerprint == fingerprint, !invalidatedKeys.contains(key) {
            disk[key]?.readStartedAt = startedAt
            touchDisk(key, now: fetchedAt)
            PersistenceMetrics.shared.skipped(.historyPages)
            return
        }
        let started = ContinuousClock.now
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let envelope = Envelope(version: Self.version, key: key, fetchedAt: fetchedAt, data: data,
                                    comparisonFingerprint: comparisonFingerprint.map { Data($0) })
            let encoded = try encoder.encode(envelope)
            guard encoded.count <= diskBudgetBytes else { return }
            let url = try fileURL(for: key)
            try encoded.write(to: url, options: .atomic)
            if let previous = disk[key] { diskBytes -= previous.bytes }
            disk[key] = DiskEntry(url: url, bytes: encoded.count, fingerprint: fingerprint, accessedAt: fetchedAt, readStartedAt: startedAt)
            invalidatedKeys.remove(key)
            diskBytes += encoded.count
            PersistenceMetrics.shared.wrote(.historyPages, bytes: encoded.count, elapsed: started.duration(to: .now))
            discardSuperseded(by: [key.lineage: key.generation])
            trimDisk()
        } catch {
            PersistenceMetrics.shared.failed(.historyPages)
            logger.notice("History page persistence failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func invalidate(threadID: String, hostID: String) {
        invalidate(.thread(hostID: hostID, threadID: threadID)) { $0.hostID == hostID && $0.threadID == threadID }
    }

    func invalidate(hostID: String) {
        invalidate(.host(hostID)) { $0.hostID == hostID }
    }

    var totalMemoryBytes: Int { memoryBytes }

    private func entry(data: Data, fetchedAt: Date, now: Date, readStartedAt: ContinuousClock.Instant?) -> Entry {
        let age = now.timeIntervalSince(fetchedAt)
        return Entry(data: data, fetchedAt: fetchedAt, isFresh: age >= 0 && age < freshnessInterval, readStartedAt: readStartedAt)
    }

    private func insertMemory(_ data: Data, for key: HistoryPageKey, fetchedAt: Date, readStartedAt: ContinuousClock.Instant?) {
        guard data.count <= memoryBudgetBytes else { return }
        removeMemory(key)
        access &+= 1
        memory[key] = MemoryEntry(data: data, fetchedAt: fetchedAt, access: access, readStartedAt: readStartedAt)
        memoryBytes += data.count
        while memoryBytes > memoryBudgetBytes, let oldest = memory.min(by: { $0.value.access < $1.value.access })?.key {
            removeMemory(oldest)
        }
    }

    private func removeMemory(_ key: HistoryPageKey) {
        if let removed = memory.removeValue(forKey: key) { memoryBytes -= removed.data.count }
    }

    private func invalidate(_ scope: Scope, matching predicate: (HistoryPageKey) -> Bool) {
        let cutoff = ContinuousClock.now
        if invalidations[scope] == nil, invalidations.count >= 64 {
            invalidationFloor = cutoff
            invalidations.removeAll(keepingCapacity: true)
        }
        invalidations[scope] = cutoff
        loadDiskIndexIfNeeded()
        for key in Array(writeOrder.keys).filter(predicate) { writeOrder.removeValue(forKey: key) }
        for key in Array(memory.keys).filter(predicate) { removeMemory(key) }
        for key in Array(disk.keys).filter(predicate) { discardDisk(key) }
    }

    private func touchDisk(_ key: HistoryPageKey, now: Date) {
        guard var record = disk[key] else { return }
        record.accessedAt = now
        disk[key] = record
        // Across launches, last-written order is sufficient for this rebuildable
        // cache. Reading a memory hit must not mutate the filesystem.
    }

    private func discardDisk(_ key: HistoryPageKey) {
        guard let removed = disk[key] else { return }
        do {
            try FileManager.default.removeItem(at: removed.url)
            disk.removeValue(forKey: key)
            diskBytes -= removed.bytes
            invalidatedKeys.remove(key)
        } catch {
            invalidatedKeys.insert(key)
            // A failed deletion is still accounted for until a later retry.
            logger.notice("Could not remove history cache file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isSuperseded(_ key: HistoryPageKey) -> Bool {
        let isNewer: @Sendable (HistoryPageKey) -> Bool = { retained in retained.generation > key.generation && retained.lineage == key.lineage }
        return memory.keys.contains(where: isNewer) || disk.keys.contains(where: isNewer) || writeOrder.keys.contains(where: isNewer)
    }

    private func discardSuperseded(by newest: [HistoryPageKey: UInt64]) {
        let isSuperseded = { (key: HistoryPageKey) in newest[key.lineage].map { key.generation < $0 } == true }
        for key in Array(memory.keys).filter(isSuperseded) { removeMemory(key) }
        for key in Array(disk.keys).filter(isSuperseded) { discardDisk(key) }
    }

    private func trimDisk() {
        for (key, _) in disk.sorted(by: { $0.value.accessedAt < $1.value.accessedAt }) {
            guard diskBytes > diskBudgetBytes else { break }
            discardDisk(key)
        }
    }

    private nonisolated static func fileURL(for key: HistoryPageKey, directory: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let hash = SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("plist")
    }

    private func fileURL(for key: HistoryPageKey) throws -> URL {
        try Self.fileURL(for: key, directory: directory)
    }

    nonisolated static func migrateRetiredAccountPages(directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "plist" {
            guard let original = try? PropertyListDecoder().decode(Envelope.self, from: Data(contentsOf: url)),
                  original.version == version,
                  var components = URLComponents(string: original.key.hostID),
                  components.queryItems?.contains(where: { $0.name == "accountId" && $0.value.flatMap(UUID.init(uuidString:)) != nil }) == true else { continue }
            components.queryItems = components.queryItems?.filter { $0.name != "accountId" && $0.name != "accountGeneration" }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            guard let hostID = components.url?.absoluteString else { continue }
            let key = HistoryPageKey(hostID: hostID, provider: original.key.provider, threadID: original.key.threadID,
                                     generation: original.key.generation, request: original.key.request)
            let target = try fileURL(for: key, directory: directory)
            if !FileManager.default.fileExists(atPath: target.path) {
                let migrated = Envelope(version: version, key: key, fetchedAt: original.fetchedAt, data: original.data,
                                        comparisonFingerprint: original.comparisonFingerprint)
                try PropertyListEncoder().encode(migrated).write(to: target, options: .atomic)
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func loadDiskIndexIfNeeded() {
        guard !loadedDiskIndex else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles
            )
            loadedDiskIndex = true
            for url in urls where url.pathExtension == "plist" {
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    guard let size = values.fileSize, size <= diskBudgetBytes else {
                        try FileManager.default.removeItem(at: url)
                        continue
                    }
                    let envelope = try PropertyListDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                    guard envelope.version == Self.version, try fileURL(for: envelope.key).lastPathComponent == url.lastPathComponent else {
                        try FileManager.default.removeItem(at: url)
                        continue
                    }
                    disk[envelope.key] = DiskEntry(url: url, bytes: size, fingerprint: envelope.comparisonFingerprint ?? Data(SHA256.hash(data: envelope.data)), accessedAt: values.contentModificationDate ?? .distantPast, readStartedAt: nil)
                    diskBytes += size
                } catch {
                    logger.notice("Ignoring invalid history cache file: \(error.localizedDescription, privacy: .public)")
                    try? FileManager.default.removeItem(at: url)
                }
            }
            discardSuperseded(by: Dictionary(disk.keys.map { ($0.lineage, $0.generation) }, uniquingKeysWith: max))
            trimDisk()
        } catch {
            logger.notice("History page cache directory unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }
}
