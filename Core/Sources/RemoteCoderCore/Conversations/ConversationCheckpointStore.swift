import Foundation
import OSLog
import SQLite3

actor ConversationCheckpointStore {
    struct PreservationFailure: LocalizedError, Sendable {
        let underlying: any Error
        var errorDescription: String? { "Local conversation data could not be preserved. \(underlying.localizedDescription)" }
    }
    struct CapacityOverflow: LocalizedError, Sendable {
        let requestedBytes: Int
        let limitBytes: Int
        var errorDescription: String? { "Local conversation storage has reached its limit. Existing conversation data was preserved." }
    }

    private let metrics: PersistenceMetrics
    private let logger = AppLogger(category: "ConversationCheckpointStore")
    enum LoadResult: Sendable {
        case checkpoint(ConversationState.Checkpoint)
        case missing
        case invalidated(ConversationState.Checkpoint?)

        var checkpoint: ConversationState.Checkpoint? {
            switch self {
        case .checkpoint(let checkpoint), .invalidated(let checkpoint?): checkpoint
            case .missing, .invalidated(nil): nil
            }
        }

        var requiresAuthoritativeHistory: Bool {
            if case .invalidated = self { return true }
            return false
        }
    }

    private enum Invalidation: String, Codable, Sendable {
        case pending, complete
    }

    struct SaveReceipt: Sendable {
        let unavailableImages: [UUID: Set<UUID>]
        let historyAdmitted: Bool
    }

    struct SubmissionRecord: Codable, Sendable {
        let revision: UInt64
        let threadID: String?
        let submission: ConversationState.Submission
    }
    private struct Envelope: Decodable, Sendable {
        let checkpoint: ConversationState.Checkpoint
    }
    private struct DatabaseEnvelope: Codable, Sendable {
        let version: Int
        let checkpoint: ConversationState.Checkpoint
        let turnIDs: [String]
        let hasHistoryWindow: Bool
    }
    private struct TurnMetadata: Codable, Sendable {
        let turn: ConversationState.Turn
        let itemIDs: [String]
    }
    private struct DiskRecord: Sendable {
        var bytes: Int
        var payloadBytes: Int
        let modified: Date
        var protected: Bool?
        var invalidation: Invalidation?
        var recoveryBytes = 0
        var importedSource: ImportedSource?
        var historyExhausted = false
        var inventoryContents: CheckpointInventory.Contents? = nil

        var cacheBytes: Int { max(0, bytes - payloadBytes) }
    }
    private let hostID: UUID
    private let allowsLegacyMigration: Bool
    private let directory: URL
    private let storage: HostStorage
    private let budgetBytes: Int
    private let primaryBudgetBytes: Int
    private var revisions: [UUID: UInt64] = [:]
    private struct Fence {
        var generation: UInt64
        var retained = false
        var operations = 0
        var invalidated = false
        var invalidationCommitted = false
        var sourceRevision: UInt64 = 0
    }
    private struct FileIdentity: Equatable, Sendable {
        let inode: UInt64
        let bytes: Int
        let modified: Date
    }
    private struct ImportedSource: Sendable {
        let url: URL
        let files: [URL: FileIdentity]
        let primaryBytes: Int
    }
    private enum SourcePayload: Sendable {
        case json(Data), sqlite([CheckpointDatabase.Record], json: Data?), unreadable(any Error)
    }
    private struct Source: Sendable {
        enum Origin: Sendable { case canonical, rollback }
        let url: URL
        let revision: UInt64
        let files: [URL: FileIdentity]
        let payload: SourcePayload
        let origin: Origin
        var companion: URL? = nil
    }
    private var fences: [UUID: Fence] = [:]
    private var nextGeneration: UInt64 = 0
    private var records: [UUID: DiskRecord] = [:]
    private var indexTask: Task<[UUID: DiskRecord], Error>?
    private var indexed = false
    private var directoryPrepared = false
    private var databases: [UUID: CheckpointDatabase] = [:]
    private var databaseRecency: [UUID] = []
    private struct EncodingStamp: Sendable {
        let turns: [String: UInt64]
        let history: UInt64?
    }
    private var encodingStamps: [UUID: EncodingStamp] = [:]
    private struct EncodedRecords: Sendable {
        let values: [CheckpointDatabase.Record]
        let finished: ContinuousClock.Instant
    }
    private var encodingTask: (id: UUID, task: Task<EncodedRecords, Error>)?
    private var omittedHistory: [UUID: ContinuousClock.Instant] = [:]
    private static let omittedHistoryLimit = 64

    init(hostID: UUID, directory: URL? = nil, storage: HostStorage = .live,
         budgetBytes: Int = 64 * 1_024 * 1_024, primaryBudgetBytes: Int, metrics: PersistenceMetrics = .shared) {
        precondition(primaryBudgetBytes > 0)
        self.hostID = hostID
        let legacy = storage.directory(for: .device).appending(path: "conversations-v1/\(hostID)")
        self.directory = directory ?? legacy
        self.storage = storage
        allowsLegacyMigration = directory == nil
        self.budgetBytes = budgetBytes
        self.primaryBudgetBytes = primaryBudgetBytes
        self.metrics = metrics
    }

    var retainedFenceCount: Int { fences.count }
    var retainedRevisionCount: Int { revisions.count }
    var accountedDiskBytes: Int { records.values.reduce(0) { $0 + $1.bytes } }

    func inventory(threadIDs: [UUID: String]) -> CheckpointInventory? {
        guard indexed else { return nil }
        var inventory = CheckpointInventory(hostID: hostID, cacheBudgetBytes: budgetBytes,
            primaryBudgetBytes: primaryBudgetBytes)
        let ordered = records.sorted {
            if ($0.value.protected == true) != ($1.value.protected == true) { return $0.value.protected == true }
            if $0.value.bytes != $1.value.bytes { return $0.value.bytes > $1.value.bytes }
            return $0.key.uuidString < $1.key.uuidString
        }
        for (id, record) in ordered {
            inventory.include(.init(conversationID: id, threadID: record.inventoryContents?.threadID ?? threadIDs[id],
                protected: record.protected,
                retained: fences[id]?.retained == true, invalidation: record.invalidation?.rawValue,
                primaryPayloadBytes: record.payloadBytes, cacheBytes: record.cacheBytes,
                physicalFileBytes: record.bytes, contents: record.inventoryContents))
        }
        return inventory
    }

    private var legacyDirectory: URL? {
        allowsLegacyMigration ? storage.directory(for: .device).appending(path: "codex-timelines") : nil
    }

    func generation(for id: UUID) -> UInt64 {
        let generation = ensureFence(id)
        fences[id]?.retained = true
        return generation
    }

    func release(_ id: UUID, generation: UInt64) {
        guard fences[id]?.generation == generation else { return }
        fences[id]?.retained = false
        pruneFence(id)
        pruneRevision(id)
    }

    private func ensureFence(_ id: UUID) -> UInt64 {
        if let fence = fences[id] { return fence.generation }
        nextGeneration += 1
        fences[id] = Fence(generation: nextGeneration)
        return nextGeneration
    }

    private func beginOperation(_ id: UUID, generation: UInt64?) throws -> UInt64 {
        let captured: UInt64
        if let generation {
            try validate(id, generation: generation)
            captured = generation
        } else {
            captured = ensureFence(id)
        }
        fences[id]?.operations += 1
        return captured
    }

    private func finishOperation(_ id: UUID) {
        guard let fence = fences[id], fence.operations > 0 else { preconditionFailure("Checkpoint operation has no fence") }
        fences[id]?.operations -= 1
        pruneFence(id)
        pruneRevision(id)
    }

    private func pruneFence(_ id: UUID) {
        guard let fence = fences[id], fence.operations == 0, !fence.retained,
              (!fence.invalidated || fence.invalidationCommitted), indexTask == nil else { return }
        fences.removeValue(forKey: id)
    }

    private func pruneRevision(_ id: UUID) {
        guard (fences[id]?.operations ?? 0) == 0,
              fences[id]?.retained != true || databases[id] == nil else { return }
        revisions.removeValue(forKey: id)
    }

    private func validate(_ id: UUID, generation: UInt64) throws {
        guard fences[id]?.generation == generation else { throw CancellationError() }
    }

    private func sourceChanged(_ id: UUID) {
        fences[id]?.sourceRevision += 1
        records[id]?.historyExhausted = false
    }

    private func replaceDatabase(_ values: [CheckpointDatabase.Record], retaining keys: Set<String>, id: UUID) throws -> CheckpointDatabase.Replacement {
        let replacement = try database(for: id).replace(values, retaining: keys)
        sourceChanged(id)
        return replacement
    }

    private func captureSource(_ id: UUID) throws -> Source? {
        guard let revision = fences[id]?.sourceRevision else { throw CancellationError() }
        let json = directory.appending(path: "\(id).json")
        let sqlite = directory.appending(path: "\(id).sqlite")
        if FileManager.default.fileExists(atPath: sqlite.path) {
            let values: [CheckpointDatabase.Record]
            do {
                values = try inspectionDatabase(for: id).read()
            } catch {
                return Source(url: sqlite, revision: revision, files: try sourceIdentity(sqlite), payload: .unreadable(error), origin: .canonical)
            }
            if !values.isEmpty || !FileManager.default.fileExists(atPath: json.path) {
                let jsonBytes = FileManager.default.fileExists(atPath: json.path) ? try Data(contentsOf: json) : nil
                var files = try sourceIdentity(sqlite)
                if jsonBytes != nil { files.merge(try sourceIdentity(json)) { _, current in current } }
                return Source(url: sqlite, revision: revision, files: files, payload: .sqlite(values, json: jsonBytes),
                    origin: .canonical, companion: jsonBytes == nil ? nil : json)
            }
        }
        guard FileManager.default.fileExists(atPath: json.path) else { return nil }
        let payload: SourcePayload
        do { payload = .json(try Data(contentsOf: json)) }
        catch { payload = .unreadable(error) }
        return Source(url: json, revision: revision, files: try sourceIdentity(json), payload: payload, origin: .canonical)
    }

    private func sourceIdentity(_ file: URL) throws -> [URL: FileIdentity] {
        let files = file.pathExtension == "sqlite" ? [file, URL(fileURLWithPath: file.path + "-wal"), URL(fileURLWithPath: file.path + "-shm")] : [file]
        var result: [URL: FileIdentity] = [:]
        for file in files {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let inode = attributes[.systemFileNumber] as? NSNumber,
                      let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else {
                    throw CocoaError(.fileReadUnknown)
                }
                result[file] = FileIdentity(inode: inode.uint64Value, bytes: size.intValue, modified: date)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        }
        return result
    }

    private func sourceIdentity(_ source: Source) throws -> [URL: FileIdentity] {
        var files = try sourceIdentity(source.url)
        if let companion = source.companion { files.merge(try sourceIdentity(companion)) { _, current in current } }
        return files
    }

    @concurrent private static func decodeSource(_ source: SourcePayload) async throws -> ConversationState.Checkpoint? {
        switch source {
        case .json(let bytes): try decodeJSON(bytes)
        case .sqlite(let values, let json): try decodeCombined(values, json: json)
        case .unreadable(let error): throw error
        }
    }

    private func recoveryDirectory(_ id: UUID) -> URL { directory.appending(path: "recovery/\(id)") }

    private func recoverySize(_ id: UUID) throws -> Int {
        try Self.recursiveBytes(recoveryDirectory(id))
    }

    private func refreshLoadedRecord(_ id: UUID, checkpoint: ConversationState.Checkpoint?, source: URL) throws {
        let recovery = try recoverySize(id)
        let sidecars = FileManager.default.fileExists(atPath: submissionDirectory(id).path) ? try Self.submissionBytes(submissionDirectory(id)) : 0
        let json = directory.appending(path: "\(id).json")
        let jsonBytes = FileManager.default.fileExists(atPath: json.path) ? try Self.fileBytes(json) : 0
        let primary = try Self.primaryBytes(checkpoint) + sidecars + recovery + (source.pathExtension == "sqlite" ? jsonBytes : 0)
        records[id] = DiskRecord(bytes: try diskBytes(id) + jsonBytes + sidecars + recovery,
            payloadBytes: primary, modified: records[id]?.modified ?? .now,
            protected: primary > 0, invalidation: nil, recoveryBytes: recovery,
            inventoryContents: sidecars + recovery + (source.pathExtension == "sqlite" ? jsonBytes : 0) == 0
                ? checkpoint.map(CheckpointInventory.Contents.init) : nil)
    }

    private static func recursiveBytes(_ directory: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
            .reduce(0) { total, file in
                guard let isDirectory = try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else { throw CocoaError(.fileReadUnknown) }
                return try total + (isDirectory ? recursiveBytes(file) : fileBytes(file))
            }
    }

    private func recover(_ source: Source, id: UUID) throws {
        if case .unreadable(let error) = source.payload, let failure = error as? CheckpointDatabase.Failure,
           ![SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_ERROR, SQLITE_SCHEMA].contains(failure.code) { throw error }
        try prepareDirectory()
        let root = recoveryDirectory(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let incident = UUID().uuidString
        let staging = root.appending(path: ".pending-\(incident)")
        let published = root.appending(path: incident)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { refreshRecoveryAccounting(id) }
        if source.url.pathExtension == "sqlite" || source.origin == .rollback {
            for file in source.files.keys where file != source.companion {
                try FileManager.default.copyItem(at: file, to: staging.appending(path: file.lastPathComponent))
            }
            try FileManager.default.moveItem(at: staging, to: published)
            if source.origin == .canonical { try discardDatabase(id) }
        } else {
            try FileManager.default.moveItem(at: source.url, to: staging.appending(path: source.url.lastPathComponent))
            try FileManager.default.moveItem(at: staging, to: published)
            sourceChanged(id)
        }
        logger.notice("Conversation checkpoint recovered conversation=\(id.uuidString) format=\(source.url.pathExtension)")
    }

    private func storedCheckpoint(_ id: UUID) throws -> (checkpoint: ConversationState.Checkpoint?, source: URL)? {
        let sqlite = directory.appending(path: "\(id).sqlite")
        let json = directory.appending(path: "\(id).json")
        if FileManager.default.fileExists(atPath: sqlite.path) {
            let values = try inspectionDatabase(for: id).read()
            if !values.isEmpty || !FileManager.default.fileExists(atPath: json.path) {
                let jsonBytes = FileManager.default.fileExists(atPath: json.path) ? try Data(contentsOf: json) : nil
                return (try Self.decodeCombined(values, json: jsonBytes), sqlite)
            }
        }
        if FileManager.default.fileExists(atPath: json.path) {
            return (try Self.decodeJSON(Data(contentsOf: json)), json)
        }
        return nil
    }

    private func refreshImportAccounting(_ id: UUID, source: ImportedSource) throws {
        let files = try sourceIdentity(source.url)
        let bytes = files.values.reduce(0) { $0 + $1.bytes }
        let primary = files == source.files ? source.primaryBytes : bytes
        let folder = submissionDirectory(id)
        let sidecars = FileManager.default.fileExists(atPath: folder.path) ? try Self.submissionBytes(folder) : 0
        let recovery = try recoverySize(id)
        let json = directory.appending(path: "\(id).json")
        let active = try diskBytes(id) + (FileManager.default.fileExists(atPath: json.path) ? Self.fileBytes(json) : 0)
        records[id] = DiskRecord(bytes: bytes + active + sidecars + recovery,
            payloadBytes: primary + active + sidecars + recovery, modified: .now,
            protected: primary + active + sidecars + recovery > 0, invalidation: nil,
            recoveryBytes: recovery, importedSource: files.isEmpty ? nil : source)
        if records[id]?.bytes == 0 { records.removeValue(forKey: id) }
    }

    private func refreshRecoveryAccounting(_ id: UUID) {
        guard let recovery = try? recoverySize(id) else {
            records[id]?.protected = true
            records[id]?.inventoryContents = nil
            return
        }
        if let imported = records[id]?.importedSource {
            do { try refreshImportAccounting(id, source: imported) }
            catch {
                let change = recovery - (records[id]?.recoveryBytes ?? 0)
                records[id]?.bytes += change
                records[id]?.payloadBytes += change
                records[id]?.recoveryBytes = recovery
                records[id]?.protected = true
            }
            return
        }
        if let stored = try? storedCheckpoint(id),
           (try? refreshLoadedRecord(id, checkpoint: stored.checkpoint, source: stored.source)) != nil { return }
        let previous = records[id]
        let json = directory.appending(path: "\(id).json")
        guard let active = try? diskBytes(id),
              let jsonBytes = try? (FileManager.default.fileExists(atPath: json.path) ? Self.fileBytes(json) : 0),
              let sidecars = try? (FileManager.default.fileExists(atPath: submissionDirectory(id).path) ? Self.submissionBytes(submissionDirectory(id)) : 0) else {
            records[id] = DiskRecord(bytes: (previous?.bytes ?? 0) + recovery - (previous?.recoveryBytes ?? 0),
                payloadBytes: (previous?.payloadBytes ?? 0) + recovery - (previous?.recoveryBytes ?? 0),
                modified: .now, protected: true, invalidation: previous?.invalidation, recoveryBytes: recovery)
            return
        }
        records[id] = DiskRecord(bytes: active + jsonBytes + sidecars + recovery,
            payloadBytes: active + jsonBytes + sidecars + recovery, modified: .now,
            protected: true, invalidation: previous?.invalidation, recoveryBytes: recovery)
    }

    func hasProtectedRecovery() throws -> Bool {
        try Self.recursiveBytes(directory.appending(path: "recovery")) > 0
    }

    func load(_ id: UUID, threadID: String? = nil, generation: UInt64? = nil) async throws -> ConversationState.Checkpoint? {
        try await restore(id, threadID: threadID, generation: generation).checkpoint
    }

    func restore(_ id: UUID, threadID: String?, generation: UInt64?) async throws -> LoadResult {
        let generation = try beginOperation(id, generation: generation)
        records[id]?.historyExhausted = false
        defer { finishOperation(id) }
        try await index()
        try validate(id, generation: generation)
        do {
            if try prepareInvalidation(id) {
                return .invalidated(try mergingSubmissions(into: nil, conversationID: id))
            }
            while true {
                try validate(id, generation: generation)
                guard let source = try captureSource(id) else {
                    if allowsLegacyMigration, try recoverySize(id) == 0 {
                        let legacy = storage.directory(for: .device).appending(path: "codex-timelines")
                        let file = legacy.appending(path: "\(id).json")
                        let identity = try sourceIdentity(file)
                        let revision = fences[id]?.sourceRevision
                        if !identity.isEmpty {
                            try refreshImportAccounting(id, source: ImportedSource(url: file, files: identity,
                                primaryBytes: identity.values.reduce(0) { $0 + $1.bytes }))
                        }
                        let checkpoint: ConversationState.Checkpoint?
                        do { checkpoint = try await LegacyConversationMigration.read(conversationID: id, threadID: threadID, directory: legacy) }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            try validate(id, generation: generation)
                            guard revision == fences[id]?.sourceRevision, try identity == sourceIdentity(file) else { continue }
                            guard let revision, !identity.isEmpty else { throw error }
                            records[id]?.importedSource = nil
                            try recover(Source(url: file, revision: revision, files: identity, payload: .unreadable(error), origin: .rollback), id: id)
                            continue
                        }
                        try validate(id, generation: generation)
                        guard revision == fences[id]?.sourceRevision, try identity == sourceIdentity(file) else { continue }
                        if let checkpoint {
                            try refreshImportAccounting(id, source: ImportedSource(url: file, files: identity,
                                primaryBytes: Self.primaryBytes(checkpoint)))
                            do { try await save(checkpoint, conversationID: id, generation: generation) }
                            catch is CapacityOverflow {
                                try validate(id, generation: generation)
                                guard try identity == sourceIdentity(file) else { continue }
                                let local = checkpoint.localRecords
                                return .invalidated(try mergingSubmissions(into: local, conversationID: id) ?? local)
                            }
                            try validate(id, generation: generation)
                            return .checkpoint(try mergingSubmissions(into: checkpoint, conversationID: id) ?? checkpoint)
                        }
                        if records[id]?.importedSource != nil {
                            try refreshImportAccounting(id, source: ImportedSource(url: file, files: identity, primaryBytes: 0))
                        }
                    }
                    let saved = try mergingSubmissions(into: nil, conversationID: id)
                    return try recoverySize(id) > 0 ? .invalidated(saved) : saved.map(LoadResult.checkpoint) ?? .missing
                }
                let checkpoint: ConversationState.Checkpoint?
                do {
                    checkpoint = try await Self.decodeSource(source.payload)
                    try Task.checkCancellation()
                    try validate(id, generation: generation)
                    guard source.revision == fences[id]?.sourceRevision,
                          try source.files == sourceIdentity(source) else { continue }
                } catch is CancellationError { throw CancellationError() } catch {
                    try validate(id, generation: generation)
                    guard source.revision == fences[id]?.sourceRevision,
                          try source.files == sourceIdentity(source) else { continue }
                    try recover(source, id: id)
                    revisions.removeValue(forKey: id)
                    encodingStamps.removeValue(forKey: id)
                    continue
                }
                if let checkpoint {
                    if case .sqlite(let values, .some) = source.payload,
                       let stored = try Self.decodeDatabase(values), checkpoint.durableRevision > stored.durableRevision {
                        revisions[id] = max(revisions[id] ?? 0, stored.durableRevision)
                        let complete = try mergingSubmissions(into: checkpoint, conversationID: id) ?? checkpoint
                        do { try await save(complete, conversationID: id, generation: generation) }
                        catch is CapacityOverflow {
                            try validate(id, generation: generation)
                            guard source.revision == fences[id]?.sourceRevision,
                                  try source.files == sourceIdentity(source) else { continue }
                            let local = complete.localRecords
                            return .invalidated(try mergingSubmissions(into: local, conversationID: id) ?? local)
                        }
                        try validate(id, generation: generation)
                        return .checkpoint(try mergingSubmissions(into: complete, conversationID: id) ?? complete)
                    }
                    revisions[id] = max(revisions[id] ?? 0, checkpoint.durableRevision)
                }
                let saved = try mergingSubmissions(into: checkpoint, conversationID: id)
                try refreshLoadedRecord(id, checkpoint: checkpoint, source: source.url)
                return saved.map(LoadResult.checkpoint) ?? .missing
            }
        } catch {
            if generation == fences[id]?.generation {
                records[id]?.protected = true
                revisions.removeValue(forKey: id)
                encodingStamps.removeValue(forKey: id)
            }
            throw error
        }
    }

    func saveSubmission(_ record: SubmissionRecord, conversationID: UUID, generation: UInt64) async throws {
        let generation = try beginOperation(conversationID, generation: generation)
        defer { finishOperation(conversationID) }
        _ = try prepareInvalidation(conversationID)
        try await index()
        if revisions[conversationID] == nil { _ = try await load(conversationID, generation: generation) }
        try validate(conversationID, generation: generation)
        let existing = try submissionRecords(conversationID).filter { $0.1.submission.message.id == record.submission.message.id }
        let saved = existing.map { $0.1.revision }.max()
        var absorbed = false
        if let revision = revisions[conversationID], record.revision <= revision,
           FileManager.default.fileExists(atPath: directory.appending(path: "\(conversationID).sqlite").path),
           let bytes = try inspectionDatabase(for: conversationID).read(key: Self.submissionKey(record.submission.message.id)),
           let headerBytes = try inspectionDatabase(for: conversationID).readHeader() {
            let header = try Self.decodeHeader(headerBytes).checkpoint
            if record.threadID == nil || header.threadID == nil || record.threadID == header.threadID {
                absorbed = try Self.submissionMatches(record.submission, stored: JSONDecoder().decode(ConversationState.Submission.self, from: bytes))
            }
        }
        if (saved.map { record.revision <= $0 } ?? false) || absorbed {
            try clearInvalidationAfterSubmission(conversationID)
            metrics.skipped(.checkpoints)
            return
        }
        let started = ContinuousClock.now
        do {
            let data = try JSONEncoder().encode(record)
            let folder = submissionDirectory(conversationID)
            let file = folder.appending(path: "\(record.submission.message.id).json")
            if let previous = existing.first, try !Self.submissionMatches(previous.1.submission, stored: record.submission) {
                try preserveSubmission(previous.0, id: conversationID)
            }
            let replacedBytes = FileManager.default.fileExists(atPath: file.path) ? try Self.fileBytes(file) : 0
            var admission = Admission.submission(delta: data.count - replacedBytes)
            try admitPrimaryPayload(&admission, replacing: conversationID)
            let payloadBytes = try admissionBytes(admission, id: conversationID)
            try prepareDirectory()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            records[conversationID] = DiskRecord(bytes: (records[conversationID]?.bytes ?? 0) - replacedBytes + data.count,
                payloadBytes: payloadBytes, modified: .now, protected: true, invalidation: records[conversationID]?.invalidation,
                recoveryBytes: records[conversationID]?.recoveryBytes ?? 0)
            try clearInvalidationAfterSubmission(conversationID)
            records[conversationID]?.protected = true
            metrics.wrote(.checkpoints, bytes: data.count, elapsed: started.duration(to: .now))
        } catch {
            metrics.failed(.checkpoints)
            throw error
        }
    }

    private func clearInvalidationAfterSubmission(_ id: UUID) throws {
        guard fences[id]?.invalidated == true else { return }
        _ = try replaceDatabase([], retaining: [], id: id)
        fences[id]?.invalidated = false
        fences[id]?.invalidationCommitted = false
        records[id]?.invalidation = nil
    }

    @discardableResult
    func save(_ supplied: ConversationState.Checkpoint, conversationID: UUID, generation: UInt64? = nil,
              presented: Bool = true) async throws -> SaveReceipt {
        var timing = metrics.beginCheckpointSave()
        defer { timing.finish() }
        var checkpoint = supplied
        let generation = try beginOperation(conversationID, generation: generation)
        defer { finishOperation(conversationID) }
        _ = try prepareInvalidation(conversationID)
        try await index()
        // This owner also preserves unknown bytes before direct writes;
        // callers cannot bypass preservation simply by skipping restore().
        if revisions[conversationID] == nil,
           (FileManager.default.fileExists(atPath: directory.appending(path: "\(conversationID).json").path)
            || FileManager.default.fileExists(atPath: directory.appending(path: "\(conversationID).sqlite").path)) {
            _ = try await load(conversationID, generation: generation)
        }
        try validate(conversationID, generation: generation)
        _ = try submissionRecords(conversationID)
        if let saved = committedRevision(checkpoint, id: conversationID, presented: presented) {
            try finishCommit(conversationID, revision: saved)
            metrics.skipped(.checkpoints)
            return unchangedReceipt(conversationID)
        }
        if encodingTask != nil {
            timing.advance(to: .predecessorWait)
            while let predecessor = encodingTask {
                _ = try? await predecessor.task.value
                if encodingTask?.id == predecessor.id { encodingTask = nil }
            }
        }
        try validate(conversationID, generation: generation)
        if committedRevision(checkpoint, id: conversationID, presented: presented) != nil {
            metrics.skipped(.checkpoints)
            return unchangedReceipt(conversationID)
        }
        let historyAdmitted = admitsHistory(checkpoint, id: conversationID, presented: presented)
        if !historyAdmitted {
            checkpoint = checkpoint.localRecords
            if !checkpoint.containsLocalRecords, try submissionRecords(conversationID).isEmpty {
                revisions[conversationID] = checkpoint.durableRevision
                metrics.skipped(.checkpoints)
                return SaveReceipt(unavailableImages: [:], historyAdmitted: false)
            }
        }
        timing.advance(to: .encodeWait)
        let started = ContinuousClock.now
        let encodingID = UUID()
        let previous = historyAdmitted && omittedHistory[conversationID] != nil ? nil : encodingStamps[conversationID]
        let encodedImages = checkpoint.unavailableImages
        let task = Task { [checkpoint, previous, metrics] in try await Self.encodeRecords(checkpoint, previous: previous, submitted: started, metrics: metrics) }
        encodingTask = (encodingID, task)
        var encoded: [CheckpointDatabase.Record]
        do {
            let result = try await task.value
            metrics.recordCheckpointPhase(.encodeResume, elapsed: result.finished.duration(to: .now))
            encoded = result.values
        } catch {
            if encodingTask?.id == encodingID { encodingTask = nil }
            metrics.failed(.checkpoints)
            throw error
        }
        if encodingTask?.id == encodingID { encodingTask = nil }
        try validate(conversationID, generation: generation)
        if committedRevision(checkpoint, id: conversationID, presented: presented) != nil {
            metrics.skipped(.checkpoints)
            return unchangedReceipt(conversationID)
        }
        timing.advance(to: .admission)
        let writtenBytes: Int
        let payloadBytes: Int
        let retainedFileBytes: Int
        do {
            try prepareDirectory()
            let keys = Self.recordKeys(checkpoint)
            let submissions = try submissionRecords(conversationID)
            let pendingBytes = try submissions.reduce(0) { try $0 + Self.fileBytes($1.0) }
            let legacy = directory.appending(path: "\(conversationID).json")
            let legacyBytes = FileManager.default.fileExists(atPath: legacy.path) ? try Self.fileBytes(legacy) : 0
            retainedFileBytes = pendingBytes + legacyBytes
            let retired = try preservedImageEvictions(checkpoint, id: conversationID)
            checkpoint = checkpoint.applyingUnavailableImages(retired)
            var admission = Admission.checkpoint(checkpoint, retainedBytes: try retainedFileBytes + recoverySize(conversationID))
            if checkpoint.containsLocalRecords || !submissions.isEmpty {
                try admitPrimaryPayload(&admission, replacing: conversationID)
            }
            if case .checkpoint(let admitted, _) = admission { checkpoint = admitted }
            payloadBytes = try admissionBytes(admission, id: conversationID)
            if checkpoint.unavailableImages != encodedImages {
                encoded = try Self.encodeDatabaseRecords(checkpoint, previous: previous)
            }
            timing.advance(to: .database)
            let replacement = try replaceDatabase(encoded, retaining: keys, id: conversationID)
            writtenBytes = replacement.bytes
            metrics.recordCheckpointWrite(inputBytes: encoded.reduce(0) { $0 + $1.data.count },
                newPayloadBytes: writtenBytes, chunking: replacement.chunking, sqlCommit: replacement.sqlCommit)
        } catch {
            metrics.failed(.checkpoints)
            throw error
        }
        timing.advance(to: .finalize)
        revisions[conversationID] = checkpoint.durableRevision
        encodingStamps[conversationID] = EncodingStamp(turns: checkpoint.turnStamps, history: checkpoint.historyStamp)
        metrics.wrote(.checkpoints, bytes: writtenBytes, elapsed: started.duration(to: .now))
        fences[conversationID]?.invalidated = false
        fences[conversationID]?.invalidationCommitted = false
        records[conversationID] = DiskRecord(bytes: payloadBytes, payloadBytes: payloadBytes, modified: .now,
            protected: payloadBytes > 0, invalidation: nil)
        records[conversationID]?.bytes = try diskBytes(conversationID) + retainedFileBytes + recoverySize(conversationID)
        records[conversationID]?.recoveryBytes = try recoverySize(conversationID)
        records[conversationID]?.historyExhausted = !historyAdmitted
        if retainedFileBytes + (records[conversationID]?.recoveryBytes ?? 0) == 0 {
            records[conversationID]?.inventoryContents = CheckpointInventory.Contents(checkpoint)
        }
        if historyAdmitted, omittedHistory.removeValue(forKey: conversationID) != nil {
            metrics.recordReadmittedHistory(bytes: Self.historyBytes(checkpoint))
        }
        try finishCommit(conversationID, revision: checkpoint.durableRevision)
        // Unique local records and pending sends are durable user data, never cache victims.
        guard historyAdmitted else { return SaveReceipt(unavailableImages: checkpoint.unavailableImages, historyAdmitted: false) }
        var cacheBytes = records.values.reduce(0) { $0 + $1.cacheBytes }
        for (id, record) in records.sorted(by: { $0.value.modified < $1.value.modified }) where cacheBytes > budgetBytes {
            guard id != conversationID, (fences[id]?.operations ?? 0) == 0 else { continue }
            if try requiresPreservation(id) {
                guard try shedHistory(id) else { continue }
            } else {
                try evictCheckpoint(id)
                revisions.removeValue(forKey: id)
                omitHistory(id)
            }
            cacheBytes -= record.cacheBytes - (records[id]?.cacheBytes ?? 0)
        }
        if cacheBytes > budgetBytes {
            logger.notice("Checkpoint cache stays over its allowance cacheBytes=\(cacheBytes) limitBytes=\(self.budgetBytes)")
        }
        return SaveReceipt(unavailableImages: checkpoint.unavailableImages, historyAdmitted: true)
    }

    private func committedRevision(_ checkpoint: ConversationState.Checkpoint, id: UUID, presented: Bool) -> UInt64? {
        guard let saved = revisions[id], checkpoint.durableRevision <= saved,
              !(checkpoint.durableRevision == saved && presented && omittedHistory[id] != nil) else { return nil }
        return saved
    }

    private func unchangedReceipt(_ id: UUID) -> SaveReceipt {
        SaveReceipt(unavailableImages: [:], historyAdmitted: omittedHistory[id] == nil)
    }

    private func admitsHistory(_ checkpoint: ConversationState.Checkpoint, id: UUID, presented: Bool) -> Bool {
        guard omittedHistory[id] != nil, !presented else { return true }
        let others = records.reduce(0) { $0 + ($1.key == id ? 0 : $1.value.cacheBytes) }
        let estimate = Self.historyBytes(checkpoint)
        guard others + estimate > budgetBytes else { return true }
        metrics.recordDeferredHistory(bytes: estimate)
        return false
    }

    private func omitHistory(_ id: UUID) {
        omittedHistory[id] = .now
        metrics.recordHistoryShed()
        guard omittedHistory.count > Self.omittedHistoryLimit,
              let oldest = omittedHistory.min(by: { $0.value < $1.value })?.key else { return }
        omittedHistory.removeValue(forKey: oldest)
    }

    private static func historyBytes(_ checkpoint: ConversationState.Checkpoint) -> Int {
        checkpoint.turns.values.reduce(checkpoint.historyWindow?.encodedBytes ?? 0) { total, turn in
            turn.items.values.reduce(total) { $0 + ($1.isLocal ? 0 : $1.encodedBytes) }
        }
    }

    private func shedHistory(_ id: UUID) throws -> Bool {
        guard (fences[id]?.operations ?? 0) == 0, records[id]?.invalidation == nil,
              records[id]?.historyExhausted != true else { return false }
        let started = ContinuousClock.now
        let stored: (checkpoint: ConversationState.Checkpoint?, source: URL)?
        do {
            defer { metrics.recordCheckpointPhase(.historyShedRead, elapsed: started.duration(to: .now)) }
            stored = try storedCheckpoint(id)
        } catch { return false }
        guard let checkpoint = stored?.checkpoint, checkpoint.containsLocalRecords else {
            records[id]?.historyExhausted = true
            return false
        }
        let local = checkpoint.localRecords
        let hasHistory = checkpoint.historyWindow != nil || checkpoint.turns.contains { key, turn in
            turn.items.count != local.turns[key]?.items.count || turn.items.contains { $0.value.localMessage != nil && !$0.value.isLocal && $0.value.detailed }
        }
        guard hasHistory else {
            records[id]?.historyExhausted = true
            return false
        }
        let values = try Self.encodeDatabaseRecords(local, previous: nil)
        _ = try replaceDatabase(values, retaining: Self.recordKeys(local), id: id)
        try database(for: id).compact()
        metrics.recordCheckpointCompaction()
        encodingStamps.removeValue(forKey: id)
        try refreshLoadedRecord(id, checkpoint: local, source: directory.appending(path: "\(id).sqlite"))
        try finishCommit(id, revision: local.durableRevision)
        records[id]?.historyExhausted = true
        omitHistory(id)
        return true
    }

    private enum Admission {
        case submission(delta: Int)
        case checkpoint(ConversationState.Checkpoint, retainedBytes: Int)
    }

    private func admissionBytes(_ admission: Admission, id: UUID) throws -> Int {
        switch admission {
        case .submission(let delta): try storedPayloadBytes(id) + delta
        case .checkpoint(let checkpoint, let retainedBytes): try Self.primaryBytes(checkpoint) + retainedBytes
        }
    }

    private func requestedBytes(_ admission: Admission, id: UUID) throws -> Int {
        var requested = try admissionBytes(admission, id: id)
        for candidate in Array(records.keys) where candidate != id {
            if try requiresPreservation(candidate) {
                guard let record = records[candidate] else { throw PreservationFailure(underlying: CocoaError(.fileReadUnknown)) }
                requested += record.payloadBytes
            }
        }
        return requested
    }

    private struct ImageVictim {
        let id: UUID
        let checkpoint: ConversationState.Checkpoint
        let image: ConversationState.Checkpoint.SettledImage
    }

    private func oldestSettledImage(_ admission: Admission, id: UUID) throws -> ImageVictim? {
        var oldest: ImageVictim?
        for candidate in Set(records.keys).union([id]) {
            let checkpoint: ConversationState.Checkpoint
            if candidate == id, case .checkpoint(let incoming, _) = admission { checkpoint = incoming }
            else {
                guard (fences[candidate]?.operations ?? 0) == 0 || candidate == id,
                      records[candidate]?.invalidation == nil,
                      let stored = try? storedCheckpoint(candidate), let loaded = stored.checkpoint else { continue }
                checkpoint = loaded
            }
            for image in checkpoint.settledImages {
                if let previous = oldest {
                    if image.date > previous.image.date { continue }
                    if image.date == previous.image.date, image.messageID.uuidString >= previous.image.messageID.uuidString { continue }
                }
                oldest = ImageVictim(id: candidate, checkpoint: checkpoint, image: image)
            }
        }
        return oldest
    }

    private func preservedImageEvictions(_ checkpoint: ConversationState.Checkpoint, id: UUID) throws -> [UUID: Set<UUID>] {
        guard FileManager.default.fileExists(atPath: directory.appending(path: "\(id).sqlite").path) else { return [:] }
        var unavailable: [UUID: Set<UUID>] = [:]
        for (turnID, turn) in checkpoint.turns {
            for (itemID, item) in turn.items {
                guard !item.isLocal, let message = item.localMessage,
                      message.attachments.contains(where: { if case .imageData = $0.content { true } else { false } }),
                      let bytes = try inspectionDatabase(for: id).read(key: Self.itemKey(turnID: turnID, itemID: itemID)) else { continue }
                let stored = try JSONDecoder().decode(ConversationState.Item.self, from: bytes)
                guard stored.localMessage?.id == message.id else { continue }
                for attachment in stored.localMessage?.attachments ?? [] {
                    if case .unavailableImage = attachment.content { unavailable[message.id, default: []].insert(attachment.id) }
                }
            }
        }
        return unavailable
    }

    private func admitPrimaryPayload(_ admission: inout Admission, replacing id: UUID) throws {
        for (candidate, fence) in fences where fence.invalidated && !fence.invalidationCommitted {
            guard try Self.readInvalidation(directory.appending(path: "\(candidate).sqlite")) != nil else {
                throw PreservationFailure(underlying: CocoaError(.fileReadCorruptFile))
            }
            try refreshPendingInvalidationRecord(candidate)
        }
        let proposedBytes = try admissionBytes(admission, id: id)
        if records.values.reduce(0, { $0 + $1.bytes }) + proposedBytes > primaryBudgetBytes {
            for candidate in Array(records.keys) where candidate != id { _ = try shedHistory(candidate) }
        }
        var requested = try requestedBytes(admission, id: id)
        let irreducible: Int
        switch admission {
        case .submission(let delta): irreducible = delta
        case .checkpoint(let checkpoint, let retainedBytes):
            var unavailable: [UUID: Set<UUID>] = [:]
            for image in checkpoint.settledImages { unavailable[image.messageID, default: []].insert(image.attachmentID) }
            irreducible = try Self.primaryBytes(checkpoint.applyingUnavailableImages(unavailable)) + retainedBytes
        }
        if irreducible > primaryBudgetBytes { try refusePrimaryAdmission(requested) }
        while requested > primaryBudgetBytes, let victim = try oldestSettledImage(admission, id: id) {
            let updated = victim.checkpoint.applyingUnavailableImages([victim.image.messageID: [victim.image.attachmentID]])
            if victim.id == id, case .checkpoint(_, let retainedBytes) = admission {
                admission = .checkpoint(updated, retainedBytes: retainedBytes)
            } else {
                let values = try Self.encodeDatabaseRecords(updated, previous: nil)
                _ = try replaceDatabase(values, retaining: Self.recordKeys(updated), id: victim.id)
                encodingStamps.removeValue(forKey: victim.id)
                try refreshLoadedRecord(victim.id, checkpoint: updated, source: directory.appending(path: "\(victim.id).sqlite"))
                try finishCommit(victim.id, revision: updated.durableRevision)
            }
            requested = try requestedBytes(admission, id: id)
        }
        if requested > primaryBudgetBytes { try refusePrimaryAdmission(requested) }
    }

    private func refusePrimaryAdmission(_ requested: Int) throws -> Never {
        logger.error("Primary checkpoint admission refused requestedBytes=\(requested) limitBytes=\(self.primaryBudgetBytes)")
        throw CapacityOverflow(requestedBytes: requested, limitBytes: primaryBudgetBytes)
    }

    private func storedPayloadBytes(_ id: UUID) throws -> Int {
        guard try requiresPreservation(id) else { return 0 }
        guard let record = records[id] else { throw PreservationFailure(underlying: CocoaError(.fileReadUnknown)) }
        return record.payloadBytes
    }

    private static func fileBytes(_ file: URL) throws -> Int {
        guard let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw CocoaError(.fileReadUnknown) }
        return bytes
    }

    private static func submissionBytes(_ folder: URL) throws -> Int {
        guard let isDirectory = try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
            throw CocoaError(.fileReadUnknown)
        }
        if !isDirectory { return try fileBytes(folder) }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { try $0 + fileBytes($1) }
    }

    private func requiresPreservation(_ id: UUID) throws -> Bool {
        if let imported = records[id]?.importedSource { try refreshImportAccounting(id, source: imported) }
        guard records[id] != nil else { return false }
        if records[id]?.invalidation == .complete {
            do {
                if try !Self.hasRollbackSource(id, directory: directory, legacyDirectory: legacyDirectory) {
                    try reclaimMarker(id)
                }
            } catch {
                throw PreservationFailure(underlying: error)
            }
            if records[id] == nil { return false }
        }
        let folder = submissionDirectory(id)
        if FileManager.default.fileExists(atPath: folder.path) {
            do {
                guard try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty else { return true }
                try FileManager.default.removeItem(at: folder)
            } catch { return true }
        }
        if let protected = records[id]?.protected { return protected }
        if FileManager.default.fileExists(atPath: directory.appending(path: "\(id).sqlite").path) {
            let protected = (try? Self.decodeDatabase(inspectionDatabase(for: id).read())?.containsLocalRecords) ?? true
            records[id]?.protected = protected
            return protected
        }
        let file = directory.appending(path: "\(id).json")
        // Unknown/corrupt files stay protected for recovery.
        let protected = (try? Self.decodeJSON(Data(contentsOf: file)))?.containsLocalRecords ?? true
        records[id]?.protected = protected
        return protected
    }

    func remove(_ id: UUID) throws {
        nextGeneration += 1
        fences[id] = Fence(generation: nextGeneration, operations: fences[id]?.operations ?? 0, invalidated: true)
        defer { pruneFence(id) }
        revisions.removeValue(forKey: id)
        encodingStamps.removeValue(forKey: id)
        omittedHistory.removeValue(forKey: id)
        try writeInvalidation(.pending, id: id)
        try completeInvalidation(id)
    }

    private func writeInvalidation(_ state: Invalidation, id: UUID) throws {
        try prepareDirectory()
        let record = CheckpointDatabase.Record(key: "invalidation", data: try JSONEncoder().encode(state))
        _ = try replaceDatabase([record], retaining: [record.key], id: id)
        if state == .pending { try refreshPendingInvalidationRecord(id) }
    }

    private func refreshPendingInvalidationRecord(_ id: UUID) throws {
        let json = directory.appending(path: "\(id).json")
        let residual = FileManager.default.fileExists(atPath: json.path) ? try Self.fileBytes(json) : 0
        let sidecars = FileManager.default.fileExists(atPath: submissionDirectory(id).path) ? try Self.submissionBytes(submissionDirectory(id)) : 0
        let recovery = try recoverySize(id)
        records[id] = DiskRecord(bytes: try diskBytes(id) + residual + sidecars + recovery,
            payloadBytes: residual + sidecars + recovery, modified: .now, protected: true,
            invalidation: .pending, recoveryBytes: recovery)
    }

    private func completeInvalidation(_ id: UUID) throws {
        for file in [directory.appending(path: "\(id).json"), submissionDirectory(id)] {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        if try Self.hasRollbackSource(id, directory: directory, legacyDirectory: legacyDirectory) {
            try database(for: id).compact()
            try writeInvalidation(.complete, id: id)
            fences[id]?.invalidationCommitted = true
            try refreshMarkerRecord(id)
        } else {
            try discardDatabase(id)
            let recovery = try recoverySize(id)
            if recovery > 0 {
                records[id] = DiskRecord(bytes: recovery, payloadBytes: recovery, modified: .now,
                    protected: true, invalidation: nil, recoveryBytes: recovery)
            } else { records.removeValue(forKey: id) }
            fences[id]?.invalidationCommitted = true
        }
        revisions.removeValue(forKey: id)
        encodingStamps.removeValue(forKey: id)
    }

    private func prepareInvalidation(_ id: UUID) throws -> Bool {
        if fences[id]?.invalidated == true, fences[id]?.invalidationCommitted != true {
            try writeInvalidation(.pending, id: id)
            try completeInvalidation(id)
            return true
        }
        guard FileManager.default.fileExists(atPath: directory.appending(path: "\(id).sqlite").path) else { return false }
        let marker: Data?
        do { marker = try inspectionDatabase(for: id).readInvalidation() }
        catch let error as CheckpointDatabase.Failure where [SQLITE_NOTADB, SQLITE_CORRUPT, SQLITE_ERROR, SQLITE_SCHEMA].contains(error.code) { return false }
        catch let error as CocoaError where error.code == .fileReadCorruptFile { return false }
        guard let bytes = marker else { return false }
        guard try inspectionDatabase(for: id).read().count == 1,
              let state = try? JSONDecoder().decode(Invalidation.self, from: bytes) else { return false }
        fences[id]?.invalidated = true
        if state == .pending { try completeInvalidation(id) }
        else if try Self.hasRollbackSource(id, directory: directory, legacyDirectory: legacyDirectory) { try refreshMarkerRecord(id) }
        else { try reclaimMarker(id) }
        fences[id]?.invalidationCommitted = true
        return true
    }

    private func refreshMarkerRecord(_ id: UUID) throws {
        let folder = submissionDirectory(id)
        let payloadBytes = FileManager.default.fileExists(atPath: folder.path)
            ? try Self.submissionBytes(folder) : 0
        let recovery = try recoverySize(id)
        records[id] = DiskRecord(bytes: try diskBytes(id) + payloadBytes + recovery, payloadBytes: payloadBytes + recovery,
            modified: .now, protected: true, invalidation: .complete, recoveryBytes: recovery)
    }

    private func reclaimMarker(_ id: UUID) throws {
        let folder = submissionDirectory(id)
        let sidecars = FileManager.default.fileExists(atPath: folder.path) ? try Self.submissionBytes(folder) : 0
        let recovery = try recoverySize(id)
        try discardDatabase(id)
        if sidecars + recovery > 0 {
            records[id] = DiskRecord(bytes: sidecars + recovery, payloadBytes: sidecars + recovery, modified: .now,
                protected: true, invalidation: nil, recoveryBytes: recovery)
        } else { records.removeValue(forKey: id) }
    }

    private static func hasRollbackSource(_ id: UUID, directory: URL, legacyDirectory: URL?) throws -> Bool {
        var sources = [directory.appending(path: "\(id).json")]
        if let legacyDirectory { sources.append(legacyDirectory.appending(path: "\(id).json")) }
        for source in sources {
            do { _ = try FileManager.default.attributesOfItem(atPath: source.path); return true }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        }
        return false
    }

    private func submissionDirectory(_ id: UUID) -> URL {
        directory.appending(path: "\(id).submissions", directoryHint: .isDirectory)
    }

    private func submissionRecords(_ id: UUID) throws -> [(URL, SubmissionRecord)] {
        let folder = submissionDirectory(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        var records: [(URL, SubmissionRecord)] = []
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            do {
                let record = try JSONDecoder().decode(SubmissionRecord.self, from: Data(contentsOf: file))
                guard file.lastPathComponent == "\(record.submission.message.id).json" else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                records.append((file, record))
            } catch {
                guard let revision = fences[id]?.sourceRevision else { throw CancellationError() }
                try recover(Source(url: file, revision: revision, files: sourceIdentity(file),
                    payload: .unreadable(error), origin: .canonical), id: id)
            }
        }
        return records
    }

    private func removeAbsorbedSubmissions(_ id: UUID, revision: UInt64) throws {
        let saved = try submissionRecords(id)
        guard !saved.isEmpty else {
            if FileManager.default.fileExists(atPath: submissionDirectory(id).path) { try FileManager.default.removeItem(at: submissionDirectory(id)) }
            return
        }
        let checkpoint: ConversationState.Checkpoint?
        if let source = try captureSource(id) {
            switch source.payload {
            case .json(let data): checkpoint = try Self.decodeJSON(data)
            case .sqlite(let values, _): checkpoint = try Self.decodeDatabase(values)
            case .unreadable(let error): throw error
            }
        } else { checkpoint = nil }
        for (file, record) in saved where record.revision <= revision {
            switch try Self.submissionCoverage(record, in: checkpoint) {
            case .missing: continue
            case .conflicting: try preserveSubmission(file, id: id)
            case .absorbed:
                let bytes = try Self.fileBytes(file)
                try FileManager.default.removeItem(at: file)
                records[id]?.bytes -= bytes
                records[id]?.payloadBytes -= bytes
            }
        }
        if try FileManager.default.contentsOfDirectory(at: submissionDirectory(id), includingPropertiesForKeys: nil).isEmpty {
            try FileManager.default.removeItem(at: submissionDirectory(id))
        }
    }

    private func preserveSubmission(_ file: URL, id: UUID) throws {
        guard let revision = fences[id]?.sourceRevision else { throw CancellationError() }
        try recover(Source(url: file, revision: revision, files: sourceIdentity(file),
            payload: .unreadable(CocoaError(.fileReadCorruptFile)), origin: .canonical), id: id)
    }

    private enum SubmissionCoverage: Equatable { case missing, absorbed, conflicting }

    private static func isInitialAdmission(_ submission: ConversationState.Submission) -> Bool {
        submission.status == .submitting && submission.queue?.submissionID == nil
            && submission.deliveryError == nil && submission.canonicalQuestionOrdinal == nil
    }

    private static func submissionMatches(_ original: ConversationState.Submission, stored: ConversationState.Submission) throws -> Bool {
        var candidate = original
        if isInitialAdmission(original) {
            candidate.turnID = stored.turnID
            candidate.message.canonicalTurnID = stored.message.canonicalTurnID
            candidate.message.canonicalItemID = stored.message.canonicalItemID
            candidate.message.wasSteered = stored.message.wasSteered
            candidate.status = stored.status
            candidate.queue = stored.queue
            candidate.deliveryError = stored.deliveryError
            candidate.canonicalQuestionOrdinal = stored.canonicalQuestionOrdinal
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(candidate) == encoder.encode(stored)
    }

    private static func submissionCoverage(_ record: SubmissionRecord, in checkpoint: ConversationState.Checkpoint?) throws -> SubmissionCoverage {
        guard let checkpoint else { return .missing }
        if let expected = checkpoint.threadID, let actual = record.threadID, actual != expected { return .conflicting }
        let original = record.submission
        if let stored = checkpoint.submissions[original.message.id] {
            return try submissionMatches(original, stored: stored) ? .absorbed : .conflicting
        }
        for item in checkpoint.turns.values.flatMap({ $0.items.values }) {
            guard case .userMessage(_, let content, let clientID) = item.value,
                  clientID.flatMap(UUID.init(uuidString:)) == original.message.id else { continue }
            guard !item.isLocal, isInitialAdmission(original), let stored = item.localMessage else { return .conflicting }
            let texts = content.compactMap { input -> String? in
                if case .text(let text, _) = input { text } else { nil }
            }
            var message = original.message
            message.useCanonicalImages(content)
            message.canonicalTurnID = stored.canonicalTurnID
            message.canonicalItemID = stored.canonicalItemID
            message.wasSteered = stored.wasSteered
            let input = original.input.trimmingCharacters(in: .whitespacesAndNewlines)
            let dispatchedTexts = input.isEmpty ? [] : [input]
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try texts == dispatchedTexts && encoder.encode(message) == encoder.encode(stored) ? .absorbed : .conflicting
        }
        return .missing
    }

    private func mergingSubmissions(into checkpoint: ConversationState.Checkpoint?, conversationID: UUID) throws -> ConversationState.Checkpoint? {
        var pending: [SubmissionRecord] = []
        for (file, record) in try submissionRecords(conversationID) {
            switch try Self.submissionCoverage(record, in: checkpoint) {
            case .missing: pending.append(record)
            case .absorbed: continue
            case .conflicting: try preserveSubmission(file, id: conversationID)
            }
        }
        pending.sort { $0.revision == $1.revision ? $0.submission.message.id.uuidString < $1.submission.message.id.uuidString : $0.revision < $1.revision }
        guard !pending.isEmpty else { return checkpoint }
        var state = ConversationState(conversationID: conversationID, threadID: checkpoint?.threadID ?? pending.first?.threadID)
        if let checkpoint { state.restore(checkpoint) }
        for record in pending {
            state.submit(record.submission.message, input: record.submission.input)
            state.submissions[record.submission.message.id] = record.submission
        }
        let merged = state.checkpoint
        let revision = max(checkpoint?.durableRevision ?? 0, pending.map(\.revision).max() ?? 0)
        return ConversationState.Checkpoint(revision: max(checkpoint?.revision ?? 0, revision), threadID: merged.threadID,
            order: merged.order, turns: merged.turns, submissions: merged.submissions, historyWindow: merged.historyWindow,
            tokenUsage: merged.tokenUsage, questions: checkpoint?.questions, questionDismissals: merged.questionDismissals,
            persistenceRevision: revision, lastTurnCompletedAt: merged.lastTurnCompletedAt, accountImports: merged.accountImports)
    }

    private func index() async throws {
        guard !indexed else { return }
        let task = indexTask ?? Task { try await Self.scan(directory) }
        indexTask = task
        do {
            let scanned = try await task.value
            guard !indexed else { return }
            records.merge(scanned.filter { fences[$0.key]?.invalidated != true }) { current, _ in current }
            for (id, record) in records where record.invalidation == .complete && fences[id]?.invalidated != true {
                if try !Self.hasRollbackSource(id, directory: directory, legacyDirectory: legacyDirectory) { try reclaimMarker(id) }
            }
            indexed = true
            indexTask = nil
            for id in Array(fences.keys) { pruneFence(id) }
        } catch {
            indexTask = nil
            for id in Array(fences.keys) { pruneFence(id) }
            throw error
        }
    }

    @concurrent private static func scan(_ directory: URL) async throws -> [UUID: DiskRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        var invalidated: [UUID: Invalidation] = [:]
        for file in files where file.pathExtension == "sqlite" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let state = try? readInvalidation(file) else { continue }
            invalidated[id] = state
        }
        var records: [UUID: DiskRecord] = [:]
        for file in files where file.pathExtension == "json" || file.pathExtension == "sqlite" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            let resource = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let wal = URL(fileURLWithPath: file.path + "-wal")
            let bytes = (resource.fileSize ?? 0) + ((try? wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let payloadBytes: Int
            var protected: Bool?
            var contents: CheckpointInventory.Contents?
            if file.pathExtension == "sqlite", invalidated[id] != nil {
                payloadBytes = 0
                protected = true
            } else if file.pathExtension == "sqlite" {
                do {
                    let checkpoint = try decodeDatabase(CheckpointDatabase(url: file, access: .inspection).read())
                    payloadBytes = try primaryBytes(checkpoint)
                    contents = checkpoint.map(CheckpointInventory.Contents.init)
                    protected = payloadBytes > 0
                } catch { payloadBytes = bytes; protected = true }
            } else if invalidated[id] != nil {
                payloadBytes = try fileBytes(file)
                protected = true
            } else {
                do {
                    let checkpoint = try decodeJSON(Data(contentsOf: file))
                    payloadBytes = try primaryBytes(checkpoint)
                    contents = CheckpointInventory.Contents(checkpoint)
                    protected = payloadBytes > 0
                } catch { payloadBytes = bytes; protected = true }
            }
            let previous = records[id]
            records[id] = DiskRecord(bytes: (previous?.bytes ?? 0) + bytes,
                payloadBytes: (previous?.payloadBytes ?? 0) + payloadBytes,
                modified: max(previous?.modified ?? .distantPast, resource.contentModificationDate ?? .distantPast),
                protected: protected == true || previous?.protected == true, invalidation: invalidated[id],
                inventoryContents: previous == nil ? contents : nil)
        }
        for folder in files where folder.pathExtension == "submissions" {
            guard let id = UUID(uuidString: folder.deletingPathExtension().lastPathComponent) else { continue }
            let bytes = try submissionBytes(folder)
            guard bytes > 0 else { continue }
            let previous = records[id]
            records[id] = DiskRecord(bytes: (previous?.bytes ?? 0) + bytes,
                payloadBytes: (previous?.payloadBytes ?? 0) + bytes, modified: previous?.modified ?? .distantPast,
                protected: true, invalidation: previous?.invalidation)
        }
        let recovery = directory.appending(path: "recovery")
        if FileManager.default.fileExists(atPath: recovery.path) {
            for folder in try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil) {
                guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
                let bytes = try recursiveBytes(folder)
                let previous = records[id]
                records[id] = DiskRecord(bytes: (previous?.bytes ?? 0) + bytes,
                    payloadBytes: (previous?.payloadBytes ?? 0) + bytes, modified: previous?.modified ?? .distantPast,
                    protected: true, invalidation: previous?.invalidation, recoveryBytes: bytes)
            }
        }
        return records
    }

    private static func readInvalidation(_ file: URL) throws -> Invalidation? {
        let database = try CheckpointDatabase(url: file, access: .inspection)
        guard let bytes = try database.readInvalidation() else { return nil }
        guard try database.read().count == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(Invalidation.self, from: bytes)
    }

    isolated deinit {}

    private func finishCommit(_ id: UUID, revision: UInt64) throws {
        let legacy = directory.appending(path: "\(id).json")
        if FileManager.default.fileExists(atPath: legacy.path), let database = databases[id] {
            if let checkpoint = try Self.decodeDatabase(database.read()) {
                let bytes = try Self.fileBytes(legacy)
                let absorbed = (try? Self.mergingLocalRecords(Self.decodeJSON(Data(contentsOf: legacy)), into: checkpoint).absorbed) == true
                if !absorbed {
                    guard let revision = fences[id]?.sourceRevision else { throw CancellationError() }
                    try recover(Source(url: legacy, revision: revision, files: sourceIdentity(legacy),
                        payload: .unreadable(CocoaError(.fileReadCorruptFile)), origin: .canonical), id: id)
                    try refreshLoadedRecord(id, checkpoint: checkpoint,
                        source: directory.appending(path: "\(id).sqlite"))
                } else {
                    try FileManager.default.removeItem(at: legacy)
                    records[id]?.bytes -= bytes
                    records[id]?.payloadBytes -= bytes
                }
            }
        }
        try removeAbsorbedSubmissions(id, revision: revision)
    }

    private func prepareDirectory() throws {
        guard !directoryPrepared else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        directoryPrepared = true
    }

    private func database(for id: UUID) throws -> CheckpointDatabase {
        if let existing = databases[id] {
            databaseRecency.removeAll { $0 == id }
            databaseRecency.append(id)
            return existing
        }
        let url = directory.appending(path: "\(id).sqlite")
        let created = try CheckpointDatabase(url: url, access: .persistence)
        for name in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: name) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: name)
        }
        databases[id] = created
        databaseRecency.append(id)
        while databaseRecency.count > 16 {
            let retired = databaseRecency.removeFirst()
            databases.removeValue(forKey: retired)
            encodingStamps.removeValue(forKey: retired)
            pruneRevision(retired)
        }
        return created
    }

    private func inspectionDatabase(for id: UUID) throws -> CheckpointDatabase {
        if let existing = databases[id] { return existing }
        return try CheckpointDatabase(url: directory.appending(path: "\(id).sqlite"), access: .inspection)
    }

    private func evictCheckpoint(_ id: UUID) throws {
        if try Self.hasRollbackSource(id, directory: directory, legacyDirectory: legacyDirectory) {
            try writeInvalidation(.pending, id: id)
            fences[id]?.invalidated = true
            fences[id]?.invalidationCommitted = false
            try completeInvalidation(id)
            pruneFence(id)
            return
        }
        try discardDatabase(id)
        let json = directory.appending(path: "\(id).json")
        if FileManager.default.fileExists(atPath: json.path) { try FileManager.default.removeItem(at: json) }
        records.removeValue(forKey: id)
    }

    private func discardDatabase(_ id: UUID) throws {
        sourceChanged(id)
        databases.removeValue(forKey: id)
        databaseRecency.removeAll { $0 == id }
        encodingStamps.removeValue(forKey: id)
        try Self.discardDatabaseFiles(id, directory: directory)
    }

    private static func discardDatabaseFiles(_ id: UUID, directory: URL) throws {
        for name in ["\(id).sqlite", "\(id).sqlite-wal", "\(id).sqlite-shm"] {
            let file = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    private func diskBytes(_ id: UUID) throws -> Int {
        try ["\(id).sqlite", "\(id).sqlite-wal"].reduce(0) { bytes, name in
            let file = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: file.path) else { return bytes }
            return bytes + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    private static func turnKey(_ id: String) -> String { "turn:" + id }

    private static func itemKey(turnID: String, itemID: String) -> String {
        "item:" + Data(turnID.utf8).base64EncodedString() + ":" + itemID
    }

    private static func submissionKey(_ id: UUID) -> String { "submission:" + id.uuidString }

    private static func recordKeys(_ checkpoint: ConversationState.Checkpoint) -> Set<String> {
        var keys: Set<String> = ["header"]
        if checkpoint.historyWindow != nil { keys.insert("history") }
        for (id, turn) in checkpoint.turns {
            keys.insert(turnKey(id))
            for itemID in turn.items.keys { keys.insert(itemKey(turnID: id, itemID: itemID)) }
        }
        for id in checkpoint.submissions.keys { keys.insert(submissionKey(id)) }
        return keys
    }

    @concurrent private static func encodeRecords(_ checkpoint: ConversationState.Checkpoint, previous: EncodingStamp?,
                                                submitted: ContinuousClock.Instant, metrics: PersistenceMetrics) async throws -> EncodedRecords {
        let started = ContinuousClock.now
        metrics.recordCheckpointPhase(.encodeQueue, elapsed: submitted.duration(to: started))
        defer { metrics.recordCheckpointPhase(.encodeRun, elapsed: started.duration(to: .now)) }
        return try EncodedRecords(values: encodeDatabaseRecords(checkpoint, previous: previous), finished: .now)
    }

    private static func encodeDatabaseRecords(_ checkpoint: ConversationState.Checkpoint, previous: EncodingStamp?) throws -> [CheckpointDatabase.Record] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let header = ConversationState.Checkpoint(revision: checkpoint.revision, threadID: checkpoint.threadID,
            order: checkpoint.order, turns: [:], submissions: [:], historyWindow: nil,
            tokenUsage: checkpoint.tokenUsage, questions: checkpoint.questions, questionDismissals: checkpoint.questionDismissals,
            persistenceRevision: checkpoint.persistenceRevision, lastTurnCompletedAt: checkpoint.lastTurnCompletedAt, accountImports: checkpoint.accountImports)
        var records = [CheckpointDatabase.Record(key: "header", data: try encoder.encode(
            DatabaseEnvelope(version: 2, checkpoint: header,
                turnIDs: checkpoint.turns.keys.sorted(), hasHistoryWindow: checkpoint.historyWindow != nil)))]
        if let history = checkpoint.historyWindow,
           checkpoint.historyStamp == nil || previous?.history != checkpoint.historyStamp {
            records.append(.init(key: "history", data: try encoder.encode(history)))
        }
        for (id, turn) in checkpoint.turns where checkpoint.turnStamps[id] == nil || previous?.turns[id] != checkpoint.turnStamps[id] {
            var metadata = turn
            metadata.items = [:]
            records.append(.init(key: turnKey(id), data: try encoder.encode(TurnMetadata(turn: metadata, itemIDs: turn.items.keys.sorted()))))
            for (itemID, item) in turn.items {
                records.append(.init(key: itemKey(turnID: id, itemID: itemID), data: try encoder.encode(item)))
            }
        }
        for (id, submission) in checkpoint.submissions {
            records.append(.init(key: submissionKey(id), data: try encoder.encode(submission)))
        }
        return records
    }

    private static func decodeDatabase(_ records: [CheckpointDatabase.Record]) throws -> ConversationState.Checkpoint? {
        guard !records.isEmpty else { return nil }
        if let marker = records.first(where: { $0.key == "invalidation" }) {
            guard records.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
            _ = try JSONDecoder().decode(Invalidation.self, from: marker.data)
            return nil
        }
        var indexed: [String: Data] = [:]
        for record in records {
            guard indexed.updateValue(record.data, forKey: record.key) == nil else { throw CocoaError(.fileReadCorruptFile) }
        }
        guard let headerBytes = indexed.removeValue(forKey: "header") else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder()
        let envelope = try decodeHeader(headerBytes)
        let header = envelope.checkpoint
        var turns: [String: ConversationState.Turn] = [:]
        var submissions: [UUID: ConversationState.Submission] = [:]
        let historyBytes = indexed.removeValue(forKey: "history")
        guard (historyBytes != nil) == envelope.hasHistoryWindow else { throw CocoaError(.fileReadCorruptFile) }
        let history = try historyBytes.map { try decoder.decode(HistoryWindow.self, from: $0) }
        for id in envelope.turnIDs {
            guard let data = indexed.removeValue(forKey: turnKey(id)) else { throw CocoaError(.fileReadCorruptFile) }
            let metadata = try decoder.decode(TurnMetadata.self, from: data)
            var turn = metadata.turn
            guard turn.id == id, turn.items.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            for itemID in metadata.itemIDs {
                guard let data = indexed.removeValue(forKey: itemKey(turnID: id, itemID: itemID)) else { throw CocoaError(.fileReadCorruptFile) }
                turn.items[itemID] = try decoder.decode(ConversationState.Item.self, from: data)
            }
            turns[id] = turn
        }
        for (key, data) in indexed where key.hasPrefix("submission:") {
            let submission = try decoder.decode(ConversationState.Submission.self, from: data)
            guard key == submissionKey(submission.message.id) else { throw CocoaError(.fileReadCorruptFile) }
            submissions[submission.message.id] = submission
            indexed.removeValue(forKey: key)
        }
        guard indexed.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let checkpoint = ConversationState.Checkpoint(revision: header.revision, threadID: header.threadID, order: header.order,
            turns: turns, submissions: submissions, historyWindow: history, tokenUsage: header.tokenUsage,
            questions: header.questions, questionDismissals: header.questionDismissals,
            persistenceRevision: header.persistenceRevision, lastTurnCompletedAt: header.lastTurnCompletedAt, accountImports: header.accountImports)
        return checkpoint
    }

    private static func decodeJSON(_ data: Data) throws -> ConversationState.Checkpoint {
        try JSONDecoder().decode(Envelope.self, from: data).checkpoint
    }

    private static func decodeHeader(_ data: Data) throws -> DatabaseEnvelope {
        let envelope = try JSONDecoder().decode(DatabaseEnvelope.self, from: data)
        let header = envelope.checkpoint
        guard envelope.version == 2, header.turns.isEmpty, header.submissions.isEmpty, header.historyWindow == nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return envelope
    }

    private static func decodeCombined(_ records: [CheckpointDatabase.Record], json: Data?) throws -> ConversationState.Checkpoint? {
        let checkpoint = try decodeDatabase(records)
        guard let json else { return checkpoint }
        let imported = try decodeJSON(json)
        guard let checkpoint else { return imported }
        return try mergingLocalRecords(imported, into: checkpoint).checkpoint
    }

    private static func mergingLocalRecords(_ imported: ConversationState.Checkpoint, into checkpoint: ConversationState.Checkpoint) throws
        -> (checkpoint: ConversationState.Checkpoint, absorbed: Bool) {
        guard imported.containsLocalRecords else { return (checkpoint, true) }
        guard imported.threadID == checkpoint.threadID else { throw CocoaError(.fileReadCorruptFile) }
        let local = imported.localRecords
        let existingLocal = checkpoint.localRecords
        guard local.order.filter({ checkpoint.turns[$0] != nil }) == checkpoint.order.filter({ local.turns[$0] != nil }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var turns = checkpoint.turns
        var submissions = checkpoint.submissions
        var dismissals = checkpoint.questionDismissals ?? [:]
        var absorbed = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (id, submission) in local.submissions {
            if let existing = submissions[id] {
                guard try encoder.encode(existing) == encoder.encode(submission) else { throw CocoaError(.fileReadCorruptFile) }
            } else { submissions[id] = submission; absorbed = false }
        }
        for (id, turn) in local.turns {
            guard var merged = turns[id] else { turns[id] = turn; absorbed = false; continue }
            var metadata = merged
            var importedMetadata = turn
            metadata.items = [:]; metadata.order = []
            importedMetadata.items = [:]; importedMetadata.order = []
            guard metadata == importedMetadata else { throw CocoaError(.fileReadCorruptFile) }
            guard turn.order.filter({ merged.items[$0] != nil }) == merged.order.filter({ turn.items[$0] != nil }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for (itemID, item) in turn.items {
                if merged.items[itemID] != nil {
                    guard let existing = existingLocal.turns[id]?.items[itemID],
                          try encoder.encode(existing) == encoder.encode(item) else { throw CocoaError(.fileReadCorruptFile) }
                } else { merged.items[itemID] = item; absorbed = false }
            }
            merged.order = ConversationState.mergeOrder(existing: turn.order, observed: merged.order)
            turns[id] = merged
        }
        for (id, dismissal) in local.questionDismissals ?? [:] {
            if let existing = dismissals[id] {
                guard try encoder.encode(existing) == encoder.encode(dismissal) else { throw CocoaError(.fileReadCorruptFile) }
            } else { dismissals[id] = dismissal; absorbed = false }
        }
        guard !absorbed else { return (checkpoint, true) }
        let revision = max(checkpoint.durableRevision, imported.durableRevision) + 1
        return (ConversationState.Checkpoint(revision: max(checkpoint.revision, imported.revision) + 1,
            threadID: checkpoint.threadID, order: ConversationState.mergeOrder(existing: local.order, observed: checkpoint.order),
            turns: turns, submissions: submissions, historyWindow: checkpoint.historyWindow,
            tokenUsage: checkpoint.tokenUsage, questions: checkpoint.questions,
            questionDismissals: dismissals.isEmpty ? nil : dismissals, persistenceRevision: revision,
            lastTurnCompletedAt: checkpoint.lastTurnCompletedAt, accountImports: checkpoint.accountImports), false)
    }

    private static func primaryBytes(_ checkpoint: ConversationState.Checkpoint?) throws -> Int {
        guard let checkpoint, checkpoint.containsLocalRecords else { return 0 }
        return try encodeDatabaseRecords(checkpoint.localRecords, previous: nil).reduce(0) { $0 + $1.data.count }
    }

}

#if RC_PERF_HARNESS
extension ConversationCheckpointStore {
    func performanceReplayInventory() -> [String: Int] {
        ["records": records.count, "protectedRecords": records.values.filter { $0.protected == true }.count,
         "unknownProtectionRecords": records.values.filter { $0.protected == nil }.count,
         "recordBytes": records.values.reduce(0) { $0 + $1.bytes },
         "primaryPayloadBytes": records.values.reduce(0) { $0 + $1.payloadBytes },
         "cacheBytes": records.values.reduce(0) { $0 + $1.cacheBytes },
         "evictionBytes": records.values.reduce(0) { $0 + $1.cacheBytes },
         "cacheLimitBytes": budgetBytes, "primaryLimitBytes": primaryBudgetBytes]
    }
}
#endif
