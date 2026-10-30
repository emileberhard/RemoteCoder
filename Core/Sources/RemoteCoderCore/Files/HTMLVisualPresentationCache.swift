import CryptoKit
import Foundation
import OSLog

actor HTMLVisualPresentationCache {
    struct Entry: Equatable, Sendable {
        let height: Double
        let hasImage: Bool
    }

    struct Snapshot: Sendable {
        let generation: UInt64
        let entries: [HTMLVisualLayoutKey: Entry]
    }

    private struct StoredImage: Codable, Equatable {
        let bytes: Int
        let file: String
        var order: UInt64
    }

    private struct Record: Codable {
        let key: HTMLVisualLayoutKey
        var height: Double
        var heightOrder: UInt64
        var image: StoredImage?
    }

    private struct Index: Codable {
        let version: Int
        let records: [Record]
    }

    private struct LegacyRecord: Codable {
        let key: HTMLVisualLayoutKey
        var height: Double
        var heightOrder: UInt64
        var image: Data?
        var imageOrder: UInt64?
    }

    private struct LegacyEnvelope: Codable {
        let version: Int
        let records: [LegacyRecord]
    }

    private struct Version: Decodable {
        let version: Int
    }

    private static let version = 3
    static let maximumHeights = 512
    static let maximumImageBytes = 24 << 20
    private static let maximumIndexBytes = 1 << 20
    private static let maximumLegacyFileBytes = (24 << 20) + (1 << 20)
    private let directory: URL
    private let clock: any Clock<Duration>
    private let logger = AppLogger(category: "HTMLVisualPresentationCache")
    private var records: [HTMLVisualLayoutKey: Record] = [:]
    private var unwrittenImages: [HTMLVisualLayoutKey: Data] = [:]
    private var committedImageFiles: Set<String> = []
    private var sequence: UInt64 = 0
    private var mutationGeneration: UInt64 = 0
    private var loaded = false
    private var retired = false
    private var dirty = false
    private var scheduledWrite: Task<Void, Never>?
    private var scheduledID: UUID?

    init(directory: URL, clock: any Clock<Duration>) {
        self.directory = directory
        self.clock = clock
    }

    isolated deinit { scheduledWrite?.cancel() }

    func load() throws -> Snapshot {
        try requireActive()
        try prepare()
        try requireActive()
        return metadata()
    }

    func image(for key: HTMLVisualLayoutKey) throws -> Data? {
        try requireActive()
        try prepare()
        try requireActive()
        guard let stored = records[key]?.image else { return nil }
        if let unwritten = unwrittenImages[key] {
            try touch(key)
            return unwritten
        }
        let data: Data
        do {
            let file = try FileHandle(forReadingFrom: imageDirectory.appending(path: stored.file))
            defer { try? file.close() }
            data = try file.read(upToCount: stored.bytes + 1) ?? Data()
        }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            try discardImage(key)
            return nil
        }
        guard data.count == stored.bytes, Self.imageFileName(data) == stored.file else {
            try discardImage(key)
            return nil
        }
        try touch(key)
        return data
    }

    func touch(_ key: HTMLVisualLayoutKey) throws {
        try requireActive()
        guard records[key] != nil else { return }
        guard sequence < UInt64.max else { throw HTMLVisualPresentationError.invalidRecord }
        sequence += 1
        records[key]?.image?.order = sequence
        records[key]?.heightOrder = sequence
    }

    func store(_ key: HTMLVisualLayoutKey, height: Double, image: Data?) throws -> Snapshot {
        try store(key, height: height, image: image, protecting: [])
    }

    func store(_ key: HTMLVisualLayoutKey, height: Double, image: Data?, protecting protected: Set<HTMLVisualLayoutKey>) throws -> Snapshot {
        try requireActive()
        try prepare()
        try requireActive()
        guard Self.valid(key), height.isFinite, (0...20_000).contains(height) else {
            throw HTMLVisualPresentationError.invalidRecord
        }
        guard (image?.count ?? 0) <= Self.maximumImageBytes else { throw HTMLVisualPresentationError.tooLarge }
        let protected = protected.subtracting([key])
        let protectedBytes = records.values.filter { protected.contains($0.key) }.reduce(0) { $0 + ($1.image?.bytes ?? 0) }
        guard protectedBytes + (image?.count ?? records[key]?.image?.bytes ?? 0) <= Self.maximumImageBytes,
              records[key] != nil || protected.count < Self.maximumHeights else {
            throw HTMLVisualPresentationError.capacity
        }
        guard sequence < UInt64.max, mutationGeneration < UInt64.max else { throw HTMLVisualPresentationError.invalidRecord }
        sequence += 1
        mutationGeneration += 1
        let changed = records[key]?.height != height || image != nil
        var record = records[key] ?? Record(key: key, height: height, heightOrder: sequence, image: nil)
        record.height = height
        record.heightOrder = sequence
        record.image?.order = sequence
        if let image {
            record.image = StoredImage(bytes: image.count, file: Self.imageFileName(image), order: sequence)
            unwrittenImages[key] = image
        }
        records[key] = record
        trim(protecting: protected.union([key]))
        if changed {
            dirty = true
            scheduleWrite()
        } else {
            PersistenceMetrics.shared.skipped(.htmlVisuals)
        }
        return metadata()
    }

    func flush() async throws {
        let work = scheduledWrite
        work?.cancel()
        scheduledWrite = nil
        scheduledID = nil
        await work?.value
        try writePending()
    }

    func retire() async throws {
        retired = true
        try await flush()
    }

    private func requireActive() throws {
        try Task.checkCancellation()
        guard !retired else { throw HTMLVisualPresentationError.retired }
    }

    private var indexURL: URL { directory.appending(path: "index-v3.plist") }
    private var legacyURL: URL { directory.appending(path: "presentations.plist") }
    private var imageDirectory: URL { directory.appending(path: "images", directoryHint: .isDirectory) }

    private static func imageFileName(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".pdf"
    }

    private func prepare() throws {
        guard !loaded else { return }
        let file: FileHandle
        var migrating = false
        do { file = try FileHandle(forReadingFrom: indexURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            do { file = try FileHandle(forReadingFrom: legacyURL) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                removeOrphanedImages(keeping: [])
                loaded = true
                return
            }
            migrating = true
        }
        defer { try? file.close() }
        guard let data = try file.read(upToCount: Self.maximumLegacyFileBytes + 1),
              data.count <= Self.maximumLegacyFileBytes else { throw HTMLVisualPresentationError.invalidRecord }
        let version = try PropertyListDecoder().decode(Version.self, from: data).version
        switch version {
        case Self.version:
            guard data.count <= Self.maximumIndexBytes else { throw HTMLVisualPresentationError.invalidRecord }
            try restore(PropertyListDecoder().decode(Index.self, from: data).records)
        case 1...2:
            try restoreLegacy(PropertyListDecoder().decode(LegacyEnvelope.self, from: data))
        default:
            throw HTMLVisualPresentationError.invalidRecord
        }
        committedImageFiles = referencedImageFiles().subtracting(Set(unwrittenImages.values.map(Self.imageFileName)))
        removeOrphanedImages(keeping: referencedImageFiles())
        if migrating {
            dirty = true
            try writePending()
        } else {
            try removeLegacyFile()
        }
        loaded = true
    }

    private func removeLegacyFile() throws {
        do { try FileManager.default.removeItem(at: legacyURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }

    private func restore(_ stored: [Record]) throws {
        guard stored.count <= Self.maximumHeights else { throw HTMLVisualPresentationError.invalidRecord }
        var restored: [HTMLVisualLayoutKey: Record] = [:]
        var imageBytes = 0
        var latest: UInt64 = 0
        for var record in stored {
            guard Self.valid(record.key), record.height.isFinite, (0...20_000).contains(record.height),
                  restored[record.key] == nil else {
                throw HTMLVisualPresentationError.invalidRecord
            }
            if let image = record.image {
                let size = (try? imageDirectory.appending(path: image.file).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if size == image.bytes, (0...Self.maximumImageBytes).contains(image.bytes),
                   image.file.count == 68, image.file.hasSuffix(".pdf"),
                   image.file.prefix(64).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                    imageBytes += image.bytes
                } else {
                    record.image = nil
                    dirty = true
                }
            }
            latest = max(latest, max(record.heightOrder, record.image?.order ?? 0))
            restored[record.key] = record
        }
        guard imageBytes <= Self.maximumImageBytes else {
            throw HTMLVisualPresentationError.invalidRecord
        }
        records = restored
        sequence = latest
    }

    private func restoreLegacy(_ envelope: LegacyEnvelope) throws {
        guard envelope.records.count <= Self.maximumHeights else { throw HTMLVisualPresentationError.invalidRecord }
        var restored: [HTMLVisualLayoutKey: Record] = [:]
        var images: [HTMLVisualLayoutKey: Data] = [:]
        var imageBytes = 0
        var latest: UInt64 = 0
        for legacy in envelope.records {
            guard Self.valid(legacy.key), legacy.height.isFinite, (0...20_000).contains(legacy.height),
                  restored[legacy.key] == nil,
                  (legacy.image == nil) == (legacy.imageOrder == nil) else {
                throw HTMLVisualPresentationError.invalidRecord
            }
            var record = Record(key: legacy.key, height: legacy.height, heightOrder: legacy.heightOrder, image: nil)
            if envelope.version == 2, let image = legacy.image, let order = legacy.imageOrder {
                record.image = StoredImage(bytes: image.count, file: Self.imageFileName(image), order: order)
                images[legacy.key] = image
                imageBytes += image.count
            }
            latest = max(latest, max(record.heightOrder, record.image?.order ?? 0))
            restored[legacy.key] = record
        }
        guard imageBytes <= Self.maximumImageBytes else {
            throw HTMLVisualPresentationError.invalidRecord
        }
        records = restored
        unwrittenImages = images
        sequence = latest
        dirty = true
    }

    private func removeOrphanedImages(keeping referenced: Set<String>) {
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path)
            for file in files where !referenced.contains(file) {
                try FileManager.default.removeItem(at: imageDirectory.appending(path: file))
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
        } catch {
            logger.error("Could not reclaim unused HTML visual images: \(error.localizedDescription)")
        }
    }

    private func referencedImageFiles() -> Set<String> {
        Set(records.values.compactMap { $0.image?.file })
    }

    private func discardImage(_ key: HTMLVisualLayoutKey) throws {
        guard records[key]?.image != nil else { return }
        guard mutationGeneration < UInt64.max else { throw HTMLVisualPresentationError.invalidRecord }
        mutationGeneration += 1
        records[key]?.image = nil
        unwrittenImages.removeValue(forKey: key)
        dirty = true
        scheduleWrite()
    }

    private static func valid(_ key: HTMLVisualLayoutKey) -> Bool {
        key.rendererVersion == 1 && key.width > 0 && key.width <= 20_000
            && key.digest.utf8.count == 64
            && key.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            && key.theme.fontSize.isFinite && key.theme.fontSize > 0 && key.theme.fontSize <= 1_000
            && [key.theme.text, key.theme.secondaryText, key.theme.background, key.theme.surface, key.theme.accent]
                .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 })
    }

    private func metadata() -> Snapshot {
        Snapshot(generation: mutationGeneration, entries: records.mapValues { Entry(height: $0.height, hasImage: $0.image != nil) })
    }

    private func trim(protecting protected: Set<HTMLVisualLayoutKey>) {
        let oldestHeights = records.values.filter { !protected.contains($0.key) }.sorted { $0.heightOrder < $1.heightOrder }
        for record in oldestHeights.prefix(max(0, records.count - Self.maximumHeights)) {
            unwrittenImages.removeValue(forKey: record.key)
            records.removeValue(forKey: record.key)
        }
        let images = records.values.filter { $0.image != nil }.sorted { ($0.image?.order ?? 0) < ($1.image?.order ?? 0) }
        var bytes = images.reduce(0) { $0 + ($1.image?.bytes ?? 0) }
        for record in images {
            guard bytes > Self.maximumImageBytes else { break }
            if protected.contains(record.key) { continue }
            records[record.key]?.image = nil
            unwrittenImages.removeValue(forKey: record.key)
            bytes -= record.image?.bytes ?? 0
        }
    }

    private func scheduleWrite() {
        guard scheduledWrite == nil else { return }
        let id = UUID()
        scheduledID = id
        let clock = clock
        scheduledWrite = Task { [weak self] in
            do {
                try await clock.sleep(for: .seconds(1))
                try Task.checkCancellation()
                await self?.performScheduledWrite(id)
            } catch is CancellationError {
            } catch {
                await self?.reportFailure(error, id: id)
            }
        }
    }

    private func performScheduledWrite(_ id: UUID) {
        guard scheduledID == id else { return }
        scheduledWrite = nil
        scheduledID = nil
        do { try writePending() }
        catch { logger.error("Could not persist HTML visual presentation: \(error.localizedDescription)") }
    }

    private func reportFailure(_ error: any Error, id: UUID) {
        guard scheduledID == id else { return }
        scheduledWrite = nil
        scheduledID = nil
        logger.error("Could not schedule HTML visual presentation write: \(error.localizedDescription)")
    }

    private func writePending() throws {
        guard dirty else { return }
        let started = ContinuousClock.now
        var bytes = 0
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let index = try encoder.encode(Index(version: Self.version, records: records.values.sorted { $0.heightOrder < $1.heightOrder }))
            guard index.count <= Self.maximumIndexBytes else { throw HTMLVisualPresentationError.tooLarge }
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            for key in Array(unwrittenImages.keys) {
                guard let image = unwrittenImages[key], let stored = records[key]?.image else { continue }
                try image.write(to: imageDirectory.appending(path: stored.file), options: .atomic)
                unwrittenImages.removeValue(forKey: key)
                bytes += image.count
            }
            try index.write(to: indexURL, options: .atomic)
            bytes += index.count
            try removeLegacyFile()
            committedImageFiles = referencedImageFiles()
            removeOrphanedImages(keeping: committedImageFiles)
            dirty = false
            PersistenceMetrics.shared.wrote(.htmlVisuals, bytes: bytes, elapsed: started.duration(to: .now))
        } catch {
            removeOrphanedImages(keeping: committedImageFiles.union(referencedImageFiles()))
            PersistenceMetrics.shared.failed(.htmlVisuals)
            throw error
        }
    }
}

enum HTMLVisualPresentationError: Error, LocalizedError, Sendable, Equatable {
    case invalidRecord
    case tooLarge
    case retired
    case capacity

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The saved HTML visual layout is invalid."
        case .tooLarge: "The HTML visual snapshot exceeds the presentation cache limit."
        case .capacity: "The HTML visual presentation cache is full."
        case .retired: "The HTML visual presentation cache has retired."
        }
    }
}

struct HTMLVisualPresentationCoverage {
    private var generation: UInt64?
    private var images: Set<HTMLVisualLayoutKey> = []

    mutating func apply(_ snapshot: HTMLVisualPresentationCache.Snapshot) {
        guard generation.map({ snapshot.generation > $0 }) ?? true else { return }
        generation = snapshot.generation
        images = Set(snapshot.entries.filter(\.value.hasImage).keys)
    }

    func contains(_ key: HTMLVisualLayoutKey) -> Bool { images.contains(key) }
}
