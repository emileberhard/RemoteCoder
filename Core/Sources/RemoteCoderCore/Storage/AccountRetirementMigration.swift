import CryptoKit
import Foundation
import OSLog

enum AccountRetirementMigration {
    struct Plan: Sendable {
        var candidates: [UUID: Set<UUID>] = [:]
        var legacyPins: [String: [String: String]] = [:]
    }

    struct Outcome: Sendable {
        var migrated: [UUID: Set<UUID>] = [:]
        var issues: [String] = []
    }

    private struct ProtectedRecovery: LocalizedError {
        var errorDescription: String? { "A saved checkpoint needs recovery. Its source files have been retained." }
    }

    fileprivate struct Progress: Codable {
        var importVersion: Int?
        var attempts = 0
        var completed = false
        var marksImported: Bool?
        var conversations: [UUID: UUID] = [:]
        var failure: String?
    }

    private struct ThreadSafeDefaults: @unchecked Sendable {
        let value: UserDefaults
    }

    actor Ledger {
        private let preferences: ThreadSafeDefaults
        private var defaults: UserDefaults { preferences.value }
        private static let attemptLimit = 3
        private static let importVersion = 2

        @MainActor init(defaults: UserDefaults) { preferences = ThreadSafeDefaults(value: defaults) }

        func plan(hosts: [UUID], storage: HostStorage) throws -> Plan {
            defaults.removeObject(forKey: "accounts.selected-by-host.v1")
            defaults.removeObject(forKey: "accounts.selected-by-provider.v1")
            var plan = Plan(candidates: Dictionary(uniqueKeysWithValues: hosts.map { ($0, []) }))
            for name in ["hosts", "conversations-v1"] {
                let root = storage.root.appending(path: name)
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    guard let host = UUID(uuidString: directory.lastPathComponent) else { continue }
                    let accounts = directory.appending(path: "accounts")
                    guard FileManager.default.fileExists(atPath: accounts.path) else { continue }
                    for account in try FileManager.default.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil) {
                        guard let id = UUID(uuidString: account.lastPathComponent) else { continue }
                        plan.candidates[host, default: []].insert(id)
                    }
                }
            }
            for (key, value) in defaults.dictionaryRepresentation() {
                guard let pins = value as? [String: String] else { continue }
                if let (host, account) = Self.legacyAddress(key) {
                    plan.candidates[host, default: []].insert(account)
                    plan.legacyPins[key] = pins
                } else {
                    let parts = key.split(separator: ".")
                    if parts.count == 3, parts[0] == "codex", parts[1] == "pinnedSessionNames", UUID(uuidString: String(parts[2])) != nil {
                        plan.legacyPins[key] = pins
                    }
                }
            }
            return plan
        }

        func run(hosts: [UUID], excluding admittedHosts: Set<UUID>, storage: HostStorage,
                 discovered: @MainActor @Sendable (Set<UUID>) -> Void,
                 finishedHost: @MainActor @Sendable (UUID) -> Void) async -> Outcome {
            var outcome = Outcome()
            var plan: Plan
            do {
                plan = try self.plan(hosts: hosts, storage: storage)
                if admittedHosts.isEmpty {
                    try HistoryPageCache.migrateRetiredAccountPages(directory: storage.root.appending(path: "history-pages"))
                }
                plan.candidates = plan.candidates.filter { !admittedHosts.contains($0.key) }
            } catch {
                outcome.issues = ["Saved conversations could not be discovered: \(error.localizedDescription)"]
                await discovered([])
                return outcome
            }
            await discovered(Set(plan.candidates.keys))
            let oldCompleted = defaults.dictionary(forKey: "accounts.claude-host-migration.completed.v1") as? [String: [String]] ?? [:]
            for host in plan.candidates.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                let defaultJournal = storage.directory(for: .host(host)).appending(path: "retired-accounts/default.json")
                let hostPinsKey = "codex.pinnedSessionNames.\(host)"
                let hostPins = plan.legacyPins[hostPinsKey] ?? [:]
                do {
                    var progress = FileManager.default.fileExists(atPath: defaultJournal.path)
                        ? try JSONDecoder().decode(Progress.self, from: Data(contentsOf: defaultJournal)) : Progress()
                    if !progress.completed {
                        guard progress.attempts < Self.attemptLimit else {
                            outcome.issues.append("Saved read changes on \(host) could not be prepared after \(Self.attemptLimit) attempts. \(progress.failure ?? "Source data has been retained.")")
                            continue
                        }
                        progress.attempts += 1
                        try Self.save(progress, to: defaultJournal)
                        do {
                            _ = try migrateMarks(from: nil, to: storage.directory(for: .host(host)), pins: hostPins, accountID: nil)
                            defaults.removeObject(forKey: hostPinsKey)
                            progress.completed = true
                            progress.failure = nil
                            try Self.save(progress, to: defaultJournal)
                        } catch {
                            progress.failure = error.localizedDescription
                            try Self.save(progress, to: defaultJournal)
                            throw error
                        }
                    } else if defaults.object(forKey: hostPinsKey) != nil {
                        _ = try migrateMarks(from: nil, to: storage.directory(for: .host(host)), pins: hostPins, accountID: nil)
                        defaults.removeObject(forKey: hostPinsKey)
                    }
                } catch {
                    outcome.issues.append("Saved read changes on \(host) could not be prepared. Source data has been retained: \(error.localizedDescription)")
                    continue
                }
                for account in (plan.candidates[host] ?? []).sorted(by: { $0.uuidString < $1.uuidString }) {
                    if Task.isCancelled { return outcome }
                    let folder = storage.directory(for: .account(host: host, account: account))
                    let journal = storage.directory(for: .host(host)).appending(path: "retired-accounts/\(account).json")
                    do {
                        var progress = FileManager.default.fileExists(atPath: journal.path)
                            ? try JSONDecoder().decode(Progress.self, from: Data(contentsOf: journal)) : Progress()
                        if !progress.completed, (progress.importVersion ?? 1) < Self.importVersion {
                            progress.importVersion = Self.importVersion
                            progress.attempts = 0
                        }
                        guard progress.completed || progress.attempts < Self.attemptLimit else {
                            outcome.issues.append("Saved conversations on \(host) could not be imported after \(Self.attemptLimit) attempts. \(progress.failure ?? "Source data has been retained.")")
                            continue
                        }
                        if !progress.completed {
                            progress.attempts += 1
                            try Self.save(progress, to: journal)
                        }
                        do {
                            let keys = plan.legacyPins.keys.filter { Self.legacyAddress($0).map { pair in pair.0 == host && pair.1 == account } == true }
                            let pins = keys.reduce(into: [String: String]()) { result, key in
                                result.merge(plan.legacyPins[key] ?? [:]) { first, _ in first }
                            }
                            let claudeDone = FileManager.default.fileExists(atPath: folder.appending(path: "claude-host-migrated-v1").path)
                                || (oldCompleted[host.uuidString] ?? []).contains { UUID(uuidString: $0) == account }
                            if !progress.completed {
                                if claudeDone {
                                    _ = try migrateMarks(from: nil, to: storage.directory(for: .host(host)),
                                                         pins: pins, accountID: account)
                                } else {
                                    try await migrate(accountID: account, hostID: host, storage: storage, pins: pins,
                                                      progress: &progress, journal: journal)
                                }
                                for key in keys { defaults.removeObject(forKey: key) }
                                progress.completed = true
                                progress.conversations = [:]
                                progress.failure = nil
                                try Self.save(progress, to: journal)
                            }
                            for key in keys { defaults.removeObject(forKey: key) }
                            try await Self.reclaim(account: account, host: host, storage: storage)
                            outcome.migrated[host, default: []].insert(account)
                        } catch is CancellationError {
                            if !progress.completed { progress.attempts -= 1 }
                            try Self.save(progress, to: journal)
                            throw CancellationError()
                        } catch {
                            progress.failure = error.localizedDescription
                            try Self.save(progress, to: journal)
                            throw error
                        }
                    } catch is CancellationError {
                        return outcome
                    } catch {
                        logger.error("Account retirement failed host=\(host) account=\(account): \(error.localizedDescription)")
                        outcome.issues.append("Saved conversations on \(host) could not be imported. Source data has been retained: \(error.localizedDescription)")
                    }
                }
                await finishedHost(host)
            }
            return outcome
        }

        fileprivate static func save(_ progress: Progress, to journal: URL) throws {
            try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(progress).write(to: journal, options: .atomic)
        }

        private static func legacyAddress(_ key: String) -> (UUID, UUID)? {
            let parts = key.split(separator: ".")
            guard parts.count == 5, parts[0] == "codex", parts[1] == "pinnedSessionNames", parts[3] == "account",
                  let host = UUID(uuidString: String(parts[2])), let account = UUID(uuidString: String(parts[4])) else { return nil }
            return (host, account)
        }

        private static func reclaim(account: UUID, host: UUID, storage: HostStorage) async throws {
            let checkpoints = storage.root.appending(path: "conversations-v1/\(host)/accounts/\(account)")
            let source = ConversationCheckpointStore(hostID: host, directory: checkpoints, storage: storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
            guard try await !source.hasProtectedRecovery() else { throw ProtectedRecovery() }
            for folder in [storage.directory(for: .account(host: host, account: account)),
                           storage.root.appending(path: "conversations-v1/\(host)/accounts/\(account)")] {
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            }
        }
    }

    private static let logger = AppLogger(category: "AccountRetirementMigration")

    static func draftSlot(hostID: UUID, accountID: UUID, slot: UUID) -> UUID {
        identifier("draft|\(hostID)|\(accountID)|\(slot)")
    }

    static func identifier(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func migrate(accountID: UUID, hostID: UUID, storage: HostStorage, pins: [String: String],
                                progress: inout Progress, journal: URL) async throws {
        let folder = storage.directory(for: .account(host: hostID, account: accountID))
        let sourceDirectory = storage.root.appending(path: "conversations-v1/\(hostID)/accounts/\(accountID)")
        let entries = try ConversationIndex.loadIndex(from: folder.appending(path: "session-index.json"))
        let host = storage.directory(for: .host(hostID))
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        let indexURL = host.appending(path: "session-index.json")
        var current = try ConversationIndex.loadIndex(from: indexURL)
        var replacements = progress.conversations
        let source = ConversationCheckpointStore(hostID: hostID, directory: sourceDirectory, storage: storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let destination = ConversationCheckpointStore(hostID: hostID, storage: storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var conversationIDs = Set(entries.values)
        if FileManager.default.fileExists(atPath: sourceDirectory.path) {
            conversationIDs.formUnion(try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
                .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        }
        let threadsByID = Dictionary(grouping: entries, by: \.value).mapValues { $0.map(\.key) }
        guard try await !source.hasProtectedRecovery() else { throw ProtectedRecovery() }
        for id in conversationIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            let aliases = (threadsByID[id] ?? []).sorted()
            if let targetID = replacements[id] {
                for thread in aliases where current[thread] == nil { current[thread] = targetID }
                continue
            }
            let restored = try await source.restore(id, threadID: nil, generation: nil)
            guard !restored.requiresAuthoritativeHistory else { throw ProtectedRecovery() }
            let incoming = restored.checkpoint
            let thread = incoming?.threadID ?? aliases.first
            let targetID = thread.flatMap { current[$0] } ?? id
            replacements[id] = targetID
            for alias in aliases where current[alias] == nil { current[alias] = targetID }
            if let thread {
                if current[thread] == nil { current[thread] = targetID }
            }
            if let incoming {
                let existing = try await destination.load(targetID, threadID: thread)
                if existing?.accountImports?.contains(accountID) != true {
                    var merged = ConversationState(conversationID: targetID, threadID: thread)
                    if let existing { merged.restore(existing) }
                    merged.restore(incoming)
                    var checkpoint = merged.checkpoint
                    checkpoint.accountImports = (checkpoint.accountImports ?? []).union([accountID])
                    try await destination.save(checkpoint, conversationID: targetID)
                }
                try JSONEncoder().encode(current).write(to: indexURL, options: .atomic)
                progress.conversations[id] = targetID
                try Ledger.save(progress, to: journal)
                try await source.remove(id)
            }
        }
        try JSONEncoder().encode(current).write(to: indexURL, options: .atomic)
        let marks: ConversationMarksReplica
        if progress.marksImported == true {
            marks = try storedMarks(in: host)
        } else {
            marks = try migrateMarks(from: folder, to: host, pins: pins, accountID: accountID)
            progress.marksImported = true
            try Ledger.save(progress, to: journal)
        }
        try ConversationHeaderStore.adoptRetiredAccountHistory(from: folder.appending(path: "history/\(hostID.uuidString).json"),
                                                              hostID: hostID, storage: storage, pinned: Set(marks.effective.pinNames.keys))
        try mergeStagedFiles(from: folder.appending(path: "upload-staging"), into: host.appending(path: "upload-staging"))
        let draftsURL = folder.appending(path: "drafts")
        if FileManager.default.fileExists(atPath: draftsURL.appending(path: "drafts.store").path) {
            try ComposerDraftStore.importDrafts(from: draftsURL, into: host.appending(path: "drafts"),
                                               conversationIDs: replacements, scope: .retiredAccount(hostID: hostID, accountID: accountID))
        }
        try migrateMetadata(from: folder.appending(path: "codex-session-metadata.json"), to: host.appending(path: "codex-session-metadata.json"))
        try migrateVoiceHistory(from: folder.appending(path: "realtime-voice-history.json"), to: host.appending(path: "realtime-voice-history.json"))
        try copyIfMissing(folder.appending(path: "codex-models.json"), to: host.appending(path: "codex-models.json"))
    }

    private static func storedMarks(in directory: URL) throws -> ConversationMarksReplica {
        try ConversationMarksStore.storedFile(in: directory)
            .map { try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: $0)) } ?? ConversationMarksReplica()
    }

    static func mergeHostFiles(from source: URL, into target: URL) throws {
        try migrateMetadata(from: source.appending(path: "codex-session-metadata.json"), to: target.appending(path: "codex-session-metadata.json"))
        try migrateVoiceHistory(from: source.appending(path: "realtime-voice-history.json"), to: target.appending(path: "realtime-voice-history.json"))
        try mergeStagedFiles(from: source.appending(path: "upload-staging"), into: target.appending(path: "upload-staging"))
    }

    private static func migrateMarks(from source: URL?, to target: URL, pins: [String: String], accountID: UUID?) throws -> ConversationMarksReplica {
        var current = try storedMarks(in: target)
        let before = current
        current.retireDefaultScope()
        if let source, let accountID {
            try current.adopt(storedMarks(in: source), sourceID: accountID)
        }
        let pinNames = current.effective.pinNames
        let legacyPins = pins.sorted { $0.key < $1.key }.compactMap { thread, name -> ConversationMarksReplica.Pending? in
            guard pinNames[thread] == nil else { return nil }
            return .init(id: identifier("legacy-pin|\(accountID?.uuidString ?? "default")|\(thread)"), change: .pin(threadID: thread, name: name))
        }
        if !legacyPins.isEmpty {
            try current.prependPending(legacyPins)
        }
        if current != before {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try JSONEncoder().encode(current).write(to: target.appending(path: ConversationMarksStore.fileName), options: .atomic)
        }
        return current
    }

    private static func migrateMetadata(from source: URL, to target: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let incoming = try ConversationMetadataStore.load(from: source)
        var current = try ConversationMetadataStore.load(from: target)
        current.acknowledged.merge(incoming.acknowledged) { existing, _ in existing }
        current.pending.merge(incoming.pending) { existing, _ in existing }
        if let legacy = incoming.legacy {
            var merged = current.legacy ?? [:]
            merged.merge(legacy) { existing, _ in existing }
            current.legacy = merged
        }
        if let invalidated = incoming.invalidated {
            current.invalidated = (current.invalidated ?? []).union(invalidated)
        }
        if let observed = incoming.observed {
            var merged = current.observed ?? [:]
            merged.merge(observed) { existing, _ in existing }
            current.observed = merged
        }
        try ConversationMetadataStore.save(current, to: target)
    }

    private static func migrateVoiceHistory(from source: URL, to target: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let decoder = JSONDecoder()
        let incoming = try decoder.decode([String: [RealtimeVoiceHistoryStore.Entry]].self, from: Data(contentsOf: source))
        var current = FileManager.default.fileExists(atPath: target.path)
            ? try decoder.decode([String: [RealtimeVoiceHistoryStore.Entry]].self, from: Data(contentsOf: target)) : [:]
        for (thread, entries) in incoming {
            let existing = current[thread] ?? []
            let unique = entries.filter { entry in
                !existing.contains { $0.role == entry.role && $0.text == entry.text && $0.date == entry.date }
            }
            current[thread] = Array((existing + unique).sorted { $0.date < $1.date }.suffix(512))
        }
        let encoder = JSONEncoder()
        try encoder.encode(current).write(to: target, options: .atomic)
    }

    private static func mergeStagedFiles(from source: URL, into target: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        for entry in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let destination = target.appending(path: entry.lastPathComponent)
            if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try mergeStagedFiles(from: entry, into: destination)
            } else {
                try copyIfMissing(entry, to: destination)
            }
        }
    }

    private static func copyIfMissing(_ source: URL, to target: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: source, options: .mappedIfSafe).write(to: target, options: .atomic)
    }
}
