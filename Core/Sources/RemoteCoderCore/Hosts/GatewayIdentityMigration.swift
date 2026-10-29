import Foundation

actor GatewayIdentityMigration {
    private let storage: HostStorage
    init(storage: HostStorage) { self.storage = storage }

    func migrate(_ journal: GatewayIdentityImport) async throws {
        for source in journal.host.legacyIDs {
            try await performMigration(from: source, to: journal.host.id, importID: journal.id)
        }
    }

    private func performMigration(from sourceID: UUID, to gatewayID: UUID, importID: UUID) async throws {
        try Task.checkCancellation()
        guard sourceID != gatewayID else { return }
        let files = FileManager.default
        let target = storage.directory(for: .host(gatewayID))
        let marker = target.appending(path: "identity-imports/\(importID)-\(sourceID).complete")
        guard !files.fileExists(atPath: marker.path) else { return }
        let source = storage.directory(for: .host(sourceID))
        let accounts = source.appending(path: "accounts")
        if files.fileExists(atPath: accounts.path),
           try !files.contentsOfDirectory(atPath: accounts.path).isEmpty { throw MigrationFailure.retiredAccounts }
        let entries = try ConversationIndex.loadIndex(from: source.appending(path: "session-index.json"))
        let targetExists = files.fileExists(atPath: target.path)
        if files.fileExists(atPath: source.path), !targetExists {
            try files.copyItem(at: source, to: target)
        }
        let replacements = try await mergeCheckpoints(from: storage.root.appending(path: "conversations-v1/\(sourceID)"),
            sourceID: sourceID, gatewayID: gatewayID, entries: entries, target: target)
        if targetExists {
            try merge(from: source, into: target, replacements: replacements)
        }
        let history = storage.root.appending(path: "codex-thread-history/\(sourceID).json")
        if files.fileExists(atPath: history.path) {
            try ConversationHeaderStore.adoptRetiredAccountHistory(from: history, hostID: gatewayID, storage: storage, pinned: [])
        }
        try files.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker, options: .atomic)
    }

    func finish(_ journal: GatewayIdentityImport) throws {
        let files = FileManager.default
        let gatewayID = journal.host.id
        let sources = Set(journal.host.legacyIDs).subtracting([gatewayID])
        guard !sources.isEmpty else { return }
        let receipts = storage.directory(for: .host(gatewayID)).appending(path: "identity-imports")
        for source in sources {
            guard files.fileExists(atPath: receipts.appending(path: "\(journal.id)-\(source).complete").path) else {
                throw MigrationFailure.recovery
            }
        }
        let recordings = storage.root.appending(path: "dictation-recordings")
        if files.fileExists(atPath: recordings.path) {
            for directory in try files.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil) {
                let manifest = directory.appending(path: "recording.json")
                guard files.fileExists(atPath: manifest.path) else { continue }
                var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
                guard var owner = json?["owner"] as? [String: Any],
                      let value = owner["hostID"] as? String, let source = UUID(uuidString: value), sources.contains(source) else { continue }
                owner["hostID"] = gatewayID.uuidString
                json?["owner"] = owner
                if let json { try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic) }
            }
        }
        for sourceID in sources {
            for source in [storage.directory(for: .host(sourceID)),
                           storage.root.appending(path: "conversations-v1/\(sourceID)"),
                           storage.root.appending(path: "codex-thread-history/\(sourceID).json")] {
                if files.fileExists(atPath: source.path) { try files.removeItem(at: source) }
            }
        }
    }

    private func merge(from source: URL, into target: URL, replacements: [UUID: UUID]) throws {
        let drafts = source.appending(path: "drafts")
        if FileManager.default.fileExists(atPath: drafts.appending(path: "drafts.store").path) {
            try ComposerDraftStore.importDrafts(from: drafts, into: target.appending(path: "drafts"),
                                               conversationIDs: replacements, scope: .gateway)
        }
        if let file = ConversationMarksStore.storedFile(in: source) {
            let incoming = try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: file))
            var merged = try ConversationMarksStore.storedFile(in: target)
                .map { try JSONDecoder().decode(ConversationMarksReplica.self, from: Data(contentsOf: $0)) }
                ?? ConversationMarksReplica()
            try merged.mergeSameGateway(incoming)
            try JSONEncoder().encode(merged).write(to: target.appending(path: ConversationMarksStore.fileName), options: .atomic)
        }
        try AccountRetirementMigration.mergeHostFiles(from: source, into: target)
        try copyMissing(from: source, into: target, excluding: ["drafts", "conversations", "session-index.json", "accounts"])
    }

    private func mergeCheckpoints(from source: URL, sourceID: UUID, gatewayID: UUID,
                                  entries: [String: UUID], target: URL) async throws -> [UUID: UUID] {
        var current = try ConversationIndex.loadIndex(from: target.appending(path: "session-index.json"))
        let original = ConversationCheckpointStore(hostID: sourceID, directory: source, storage: storage,
                                                   primaryBudgetBytes: 512 * 1_024 * 1_024)
        let destination = ConversationCheckpointStore(hostID: gatewayID, storage: storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let aliases = Dictionary(grouping: entries, by: \.value).mapValues { $0.map(\.key) }
        var ids = Set(entries.values)
        if FileManager.default.fileExists(atPath: source.path) {
            ids.formUnion(try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        }
        guard try await !original.hasProtectedRecovery() else { throw MigrationFailure.recovery }
        var replacements: [UUID: UUID] = [:]
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let restored = try await original.restore(id, threadID: nil, generation: nil)
            guard !restored.requiresAuthoritativeHistory else { throw MigrationFailure.recovery }
            let thread = restored.checkpoint?.threadID ?? aliases[id]?.min()
            let targetID = thread.flatMap { current[$0] } ?? id
            replacements[id] = targetID
            for alias in aliases[id] ?? [] { current[alias] = targetID }
            if let incoming = restored.checkpoint {
                let existing = try await destination.load(targetID, threadID: thread)
                if existing?.accountImports?.contains(sourceID) != true {
                    var state = ConversationState(conversationID: targetID, threadID: thread)
                    if let existing { state.restore(existing) }
                    state.restore(incoming)
                    var checkpoint = state.checkpoint
                    checkpoint.accountImports = (checkpoint.accountImports ?? []).union([sourceID])
                    try await destination.save(checkpoint, conversationID: targetID)
                }
            }
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try JSONEncoder().encode(current).write(to: target.appending(path: "session-index.json"), options: .atomic)
        return replacements
    }

    private func copyMissing(from source: URL, into target: URL, excluding: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        where !excluding.contains(file.lastPathComponent) {
            let destination = target.appending(path: file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: file, to: destination)
            }
        }
    }

    enum MigrationFailure: LocalizedError {
        case recovery, retiredAccounts, verificationInProgress
        var errorDescription: String? {
            switch self {
            case .recovery: "Saved conversations need recovery before this gateway's identity can be migrated."
            case .retiredAccounts: "Saved accounts must finish importing before this gateway's identity can be migrated."
            case .verificationInProgress: "Another gateway identity is being verified. Retry when it finishes."
            }
        }
    }
}

enum GatewayIdentityPreferences {
    static func migrate(from source: UUID, to target: UUID, in defaults: UserDefaults, domainName: String) {
        guard source != target else { return }
        let sourceText = source.uuidString
        let targetText = target.uuidString
        let marker = "gateway.identityPreferences.v1.\(sourceText)"
        guard defaults.string(forKey: marker) != targetText else { return }
        let domain = defaults.persistentDomain(forName: domainName) ?? [:]
        var migrated = domain
        for (key, value) in domain where key != "gateway.hosts" {
            migrated[key] = remap(value, source: source, target: target)
        }
        for key in domain.keys where key != "gateway.hosts" {
            let renamed = key.replacingOccurrences(of: sourceText, with: targetText, options: .caseInsensitive)
            guard renamed != key else { continue }
            let incoming = migrated.removeValue(forKey: key)
            if let incoming = incoming as? [String: Any], let current = migrated[renamed] as? [String: Any] {
                migrated[renamed] = incoming.merging(current) { _, current in current }
            } else if migrated[renamed] == nil {
                migrated[renamed] = incoming
            }
        }
        for (key, value) in migrated where key != marker {
            if let previous = domain[key], NSDictionary(dictionary: ["value": previous]).isEqual(to: ["value": value]) { continue }
            defaults.set(value, forKey: key)
        }
        for key in domain.keys where migrated[key] == nil { defaults.removeObject(forKey: key) }
        defaults.set(targetText, forKey: marker)
    }

    private static func remap(_ value: Any, source: UUID, target: UUID) -> Any {
        if let string = value as? String {
            if UUID(uuidString: string) == source { return target.uuidString }
            if let separator = string.firstIndex(of: "|"), UUID(uuidString: String(string[..<separator])) == source {
                return target.uuidString + String(string[separator...])
            }
            return string
        }
        if let array = value as? [Any] { return array.map { remap($0, source: source, target: target) } }
        if let dictionary = value as? [String: Any] {
            return Dictionary(dictionary.map { key, value in
                (key.replacingOccurrences(of: source.uuidString, with: target.uuidString, options: .caseInsensitive),
                 remap(value, source: source, target: target))
            }, uniquingKeysWith: { first, _ in first })
        }
        if let data = value as? Data, let json = try? JSONSerialization.jsonObject(with: data) {
            return (try? JSONSerialization.data(withJSONObject: remap(json, source: source, target: target), options: [.fragmentsAllowed])) ?? data
        }
        return value
    }
}
