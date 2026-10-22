import Foundation
import OSLog

actor HTMLVisualPresentationCache {
    struct Entry: Equatable, Sendable {
        let height: Double
        let hasImage: Bool
    }

    private struct Record: Codable {
        let key: HTMLVisualLayoutKey
        var height: Double
        var heightOrder: UInt64
        var image: Data?
        var imageOrder: UInt64?
    }

    private struct Envelope: Codable {
        let version: Int
        let records: [Record]
    }

    private static let version = 2
    private static let maximumHeights = 256
    private static let maximumImages = 128
    private static let maximumImageBytes = 24 << 20
    private static let maximumFileBytes = (24 << 20) + (1 << 20)
    private let directory: URL
    private let clock: any Clock<Duration>
    private let logger = Logger(subsystem: "RemoteCoder", category: "HTMLVisualPresentationCache")
    private var records: [HTMLVisualLayoutKey: Record] = [:]
    private var sequence: UInt64 = 0
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

    func load() throws -> [HTMLVisualLayoutKey: Entry] {
        try requireActive()
        try prepare()
        try requireActive()
        return metadata()
    }

    func image(for key: HTMLVisualLayoutKey) throws -> Data? {
        try requireActive()
        try prepare()
        try requireActive()
        return records[key]?.image
    }

    func store(_ key: HTMLVisualLayoutKey, height: Double, image: Data?) throws -> [HTMLVisualLayoutKey: Entry] {
        try requireActive()
        try prepare()
        try requireActive()
        guard Self.valid(key), height.isFinite, (0...20_000).contains(height) else {
            throw HTMLVisualPresentationError.invalidRecord
        }
        guard (image?.count ?? 0) <= Self.maximumImageBytes else { throw HTMLVisualPresentationError.tooLarge }
        guard sequence < UInt64.max else { throw HTMLVisualPresentationError.invalidRecord }
        sequence += 1
        var record = records[key] ?? Record(key: key, height: height, heightOrder: sequence,
            image: nil, imageOrder: nil)
        record.height = height
        record.heightOrder = sequence
        if let image {
            record.image = image
            record.imageOrder = sequence
        }
        records[key] = record
        trim()
        dirty = true
        scheduleWrite()
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

    private func prepare() throws {
        guard !loaded else { return }
        let url = directory.appending(path: "presentations.plist")
        let file: FileHandle
        do { file = try FileHandle(forReadingFrom: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            loaded = true
            return
        }
        defer { try? file.close() }
        guard let data = try file.read(upToCount: Self.maximumFileBytes + 1),
              data.count <= Self.maximumFileBytes else { throw HTMLVisualPresentationError.invalidRecord }
        let envelope = try PropertyListDecoder().decode(Envelope.self, from: data)
        guard (1...Self.version).contains(envelope.version), envelope.records.count <= Self.maximumHeights else {
            throw HTMLVisualPresentationError.invalidRecord
        }
        var restored: [HTMLVisualLayoutKey: Record] = [:]
        var imageCount = 0
        var imageBytes = 0
        var latest: UInt64 = 0
        for var record in envelope.records {
            guard Self.valid(record.key), record.height.isFinite, (0...20_000).contains(record.height),
                  restored[record.key] == nil,
                  (record.image == nil) == (record.imageOrder == nil) else {
                throw HTMLVisualPresentationError.invalidRecord
            }
            if envelope.version == 1 {
                record.image = nil
                record.imageOrder = nil
            }
            if let image = record.image {
                imageCount += 1
                imageBytes += image.count
            }
            latest = max(latest, max(record.heightOrder, record.imageOrder ?? 0))
            restored[record.key] = record
        }
        guard imageCount <= Self.maximumImages, imageBytes <= Self.maximumImageBytes else {
            throw HTMLVisualPresentationError.invalidRecord
        }
        records = restored
        sequence = latest
        loaded = true
    }

    private static func valid(_ key: HTMLVisualLayoutKey) -> Bool {
        key.rendererVersion == 1 && key.width > 0 && key.width <= 20_000
            && key.digest.utf8.count == 64
            && key.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            && key.theme.fontSize.isFinite && key.theme.fontSize > 0 && key.theme.fontSize <= 1_000
            && [key.theme.text, key.theme.secondaryText, key.theme.background, key.theme.surface, key.theme.accent]
                .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 })
    }

    private func metadata() -> [HTMLVisualLayoutKey: Entry] {
        records.mapValues { Entry(height: $0.height, hasImage: $0.image != nil) }
    }

    private func trim() {
        let oldestHeights = records.values.sorted { $0.heightOrder < $1.heightOrder }
        for record in oldestHeights.prefix(max(0, records.count - Self.maximumHeights)) {
            records.removeValue(forKey: record.key)
        }
        let images = records.values.filter { $0.image != nil }.sorted { ($0.imageOrder ?? 0) < ($1.imageOrder ?? 0) }
        var count = images.count
        var bytes = images.reduce(0) { $0 + ($1.image?.count ?? 0) }
        for record in images {
            guard count > Self.maximumImages || bytes > Self.maximumImageBytes else { break }
            records[record.key]?.image = nil
            records[record.key]?.imageOrder = nil
            count -= 1
            bytes -= record.image?.count ?? 0
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
        catch { logger.error("Could not persist HTML visual presentation: \(error.localizedDescription, privacy: .public)") }
    }

    private func reportFailure(_ error: any Error, id: UUID) {
        guard scheduledID == id else { return }
        scheduledWrite = nil
        scheduledID = nil
        logger.error("Could not schedule HTML visual presentation write: \(error.localizedDescription, privacy: .public)")
    }

    private func writePending() throws {
        guard dirty else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Envelope(version: Self.version, records: records.values.sorted { $0.heightOrder < $1.heightOrder }))
        guard data.count <= Self.maximumFileBytes else { throw HTMLVisualPresentationError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try data.write(to: directory.appending(path: "presentations.plist"), options: .atomic)
        dirty = false
    }
}

enum HTMLVisualPresentationError: Error, LocalizedError, Sendable, Equatable {
    case invalidRecord
    case tooLarge
    case retired

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The saved HTML visual layout is invalid."
        case .tooLarge: "The HTML visual snapshot exceeds the presentation cache limit."
        case .retired: "The HTML visual presentation cache has retired."
        }
    }
}
