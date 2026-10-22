import Foundation
import OSLog

actor ConversationHeaderStore {
    private static let formatVersion = 4
    private static let pendingHistoryGrace: TimeInterval = 5 * 60

    struct Snapshot: Equatable, Sendable {
        let threads: [ConversationHeader]
        let lastSuccessfulRefreshAt: Date?
        var hasDiscardedHeaders = false
        let revision: UInt64
    }

    private struct Envelope: Codable, Sendable {
        let version: Int
        let updatedAt: Date
        let lastSuccessfulRefreshAt: Date?
        let threads: [ConversationHeader]
        var hasDiscardedHeaders: Bool? = nil
        var revision: UInt64? = nil
    }

    private let baseDirectory: URL
    private let logger = Logger(subsystem: "RemoteCoder", category: "ConversationHeaderStore")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let hostKey: String
    private var cache: Snapshot?
    private var persistedSnapshot: Snapshot?
    private var isRetired = false

    init(hostID: UUID?, directory: URL? = nil, storage: HostStorage = .live) {
        hostKey = hostID?.uuidString ?? "default"
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        decoder.dateDecodingStrategy = .iso8601
        baseDirectory = directory ?? Self.defaultBaseDirectory(storage: storage)
    }

    func load() -> Snapshot {
        if let cached = cache {
            return cached
        }

        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let empty = Snapshot(threads: [], lastSuccessfulRefreshAt: nil, revision: 0)
            cache = empty
            return empty
        }

        do {
            let data = try Data(contentsOf: url)
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.version == Self.formatVersion else {
                return Snapshot(threads: [], lastSuccessfulRefreshAt: nil, revision: 0)
            }
            let retained = ConversationHeaderRetention.retain(envelope.threads, prioritizing: [], pinned: [], promoting: [])
            let snapshot = Snapshot(threads: retained.threads, lastSuccessfulRefreshAt: envelope.lastSuccessfulRefreshAt,
                                    hasDiscardedHeaders: retained.discarded || envelope.hasDiscardedHeaders == true,
                                    revision: envelope.revision ?? 0)
            if retained.threads.count == envelope.threads.count { persistedSnapshot = snapshot }
            cache = snapshot
            return snapshot
        } catch {
            logger.error("Failed to load thread history cache for \(self.hostKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let empty = Snapshot(threads: [], lastSuccessfulRefreshAt: nil, revision: 0)
            cache = empty
            return empty
        }
    }

    func save(snapshot: Snapshot) {
        guard !isRetired else { return }
        let current = load()
        guard snapshot.revision >= current.revision else { return }
        guard snapshot.revision > current.revision || snapshot == current else {
            logger.error("Rejected conflicting thread history revision for \(self.hostKey, privacy: .public)")
            return
        }
        cache = snapshot

        let envelope = Envelope(
            version: Self.formatVersion,
            updatedAt: Date(),
            lastSuccessfulRefreshAt: snapshot.lastSuccessfulRefreshAt,
            threads: snapshot.threads,
            hasDiscardedHeaders: snapshot.hasDiscardedHeaders,
            revision: snapshot.revision
        )

        let started = ContinuousClock.now
        do {
            if persistedSnapshot?.threads == snapshot.threads && persistedSnapshot?.hasDiscardedHeaders == snapshot.hasDiscardedHeaders {
                PersistenceMetrics.shared.skipped(.threadHeaders)
                return
            }
            let data = try encoder.encode(envelope)
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            persistedSnapshot = snapshot
            PersistenceMetrics.shared.wrote(.threadHeaders, bytes: data.count, elapsed: started.duration(to: .now))
        } catch {
            PersistenceMetrics.shared.failed(.threadHeaders)
            logger.error("Failed to persist thread history cache for \(self.hostKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func retire() { isRetired = true }

    static func scoped(to target: ExecutionTarget, storage: HostStorage) -> ConversationHeaderStore {
        ConversationHeaderStore(hostID: target.hostID, storage: storage)
    }

    private nonisolated static func defaultBaseDirectory(storage: HostStorage) -> URL {
        storage.directory(for: .device).appendingPathComponent("codex-thread-history", isDirectory: true)
    }

    /// Synchronous read for the one-shot host-scoped migration, which has to know
    /// which host owns a thread id *before* any live store, chat model or session
    /// index exists. Everything else goes through the actor.
    nonisolated static func cachedThreadIDs(
        hostID: UUID?,
        baseDirectory: URL? = nil,
        storage: HostStorage = .live
    ) -> Set<String> {
        let directory = baseDirectory ?? defaultBaseDirectory(storage: storage)
        let url = directory.appendingPathComponent("\(hostID?.uuidString ?? "default").json", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return [] }
        struct IdentifiedEnvelope: Decodable {
            struct Row: Decodable { let id: String }
            let threads: [Row]
        }
        guard let envelope = try? JSONDecoder().decode(IdentifiedEnvelope.self, from: data) else { return [] }
        return Set(envelope.threads.map(\.id))
    }

    nonisolated static func adoptRetiredAccountHistory(from source: URL, hostID: UUID, storage: HostStorage, pinned: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming = try decoder.decode(Envelope.self, from: Data(contentsOf: source))
        guard incoming.version == formatVersion else { return }
        let target = defaultBaseDirectory(storage: storage).appending(path: "\(hostID.uuidString).json")
        let current = FileManager.default.fileExists(atPath: target.path)
            ? try decoder.decode(Envelope.self, from: Data(contentsOf: target)) : nil
        let hostPins = Set((current?.threads ?? []).map(\.id)).intersection(pinned)
        let retained = ConversationHeaderRetention.retain(merging(current: incoming.threads.filter { !$0.isDelegatedAgent },
                           fetched: current?.threads ?? []), prioritizing: hostPins, pinned: pinned, promoting: [])
        let envelope = Envelope(version: formatVersion, updatedAt: .now,
                                lastSuccessfulRefreshAt: current?.lastSuccessfulRefreshAt, threads: retained.threads,
                                hasDiscardedHeaders: retained.discarded || incoming.hasDiscardedHeaders == true || current?.hasDiscardedHeaders == true,
                                revision: max(incoming.revision ?? 0, current?.revision ?? 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(envelope).write(to: target, options: .atomic)
    }

    nonisolated static func merging(
        current: [ConversationHeader],
        fetched: [ConversationHeader]
    ) -> [ConversationHeader] {
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for var header in fetched {
            if let previous = byID[header.id] { header.retainAncestry(from: previous) }
            // Activity time is presentation data, not a version number. A newer
            // server read can correct it backward or change a title without a turn.
            byID[header.id] = header
        }
        return byID.values.sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id
        }
    }

    nonisolated static func refreshing(
        current: [ConversationHeader],
        recent: [ConversationHeader],
        continuation: ConversationListContinuation,
        retaining priorityThreadIDs: Set<String>,
        preserving localSessionIDs: Set<String> = [],
        now: Date = .now
    ) -> [ConversationHeader] {
        let ordered = merging(current: [], fetched: recent)
        let returnedIDs = Set(ordered.map(\.id))
        let oldestCodex = ordered.last { !$0.isDelegatedAgent && AgentProvider.provider(forThreadID: $0.id) == .codex }
        let oldestClaude = ordered.last { !$0.isDelegatedAgent && AgentProvider.provider(forThreadID: $0.id) == .claude }
        let retained = current.filter { thread in
            if let pendingSince = thread.pendingHistorySince, now.timeIntervalSince(pendingSince) < Self.pendingHistoryGrace { return true }
            if localSessionIDs.contains(thread.id) || priorityThreadIDs.contains(thread.id) || returnedIDs.contains(thread.id) { return true }
            let provider = AgentProvider.provider(forThreadID: thread.id)
            let position = provider == .codex ? continuation.codex : continuation.claude
            if position == .end { return false }
            let oldestRoot = provider == .codex ? oldestCodex : oldestClaude
            guard let oldest = oldestRoot else { return true }
            // An absent row claiming to be inside this authoritative page is
            // contradicted by the server. Retain only the older cached pages.
            return thread.updatedAt <= oldest.updatedAt
        }
        return merging(
            current: retained,
            fetched: ordered.filter { !localSessionIDs.contains($0.id) }
        )
    }
}

private extension ConversationHeaderStore {
    var fileURL: URL {
        baseDirectory.appendingPathComponent("\(hostKey).json", isDirectory: false)
    }
}
