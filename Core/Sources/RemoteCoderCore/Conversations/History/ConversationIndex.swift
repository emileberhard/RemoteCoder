import Foundation
import OSLog

/// Maps remote thread ids to local conversation UUIDs.
///
/// Host-scoped: two gateways can expose the same thread id, and they are
/// different conversations with different local timelines.
actor ConversationIndex {
    private let fileURL: URL
    private var map: [String: UUID] = [:]
    private var hasLoaded = false
    private var needsSave = false
    private let logger = AppLogger(category: "ConversationIndex")

    init(hostID: UUID?, storage: HostStorage = .live) {
        fileURL = storage.directory(for: .target(hostID: hostID))
            .appendingPathComponent("session-index.json", isDirectory: false)
    }

    nonisolated static func fileURL(hostID: UUID?, storage: HostStorage = .live) -> URL {
        storage.directory(for: .target(hostID: hostID))
            .appendingPathComponent("session-index.json", isDirectory: false)
    }

    /// Synchronous reads and writes for the one-shot host-scoped migration.
    ///
    /// The migration finishes before host models are created. The index loads
    /// on its first actor-isolated operation, so adopting entries behind its back
    /// would let its stale in-memory map overwrite them on the next `record`.
    nonisolated static func legacyEntriesSynchronously(directory: URL? = nil, storage: HostStorage = .live) -> [String: UUID] {
        let url = directory?.appendingPathComponent("session-index.json", isDirectory: false)
            ?? fileURL(hostID: nil, storage: storage)
        return (try? loadIndex(from: url)) ?? [:]
    }

    nonisolated static func adoptSynchronously(_ entries: [String: UUID], hostID: UUID, storage: HostStorage = .live) {
        guard entries.isEmpty == false else { return }
        let logger = AppLogger(category: "ConversationIndex")
        createDirectoryIfNeeded(hostID: hostID, storage: storage, logger: logger)
        let url = fileURL(hostID: hostID, storage: storage)
        var map = (try? loadIndex(from: url)) ?? [:]
        var didChange = false
        for (sessionID, conversationID) in entries where map[sessionID] == nil {
            map[sessionID] = conversationID
            didChange = true
        }
        guard didChange else { return }
        do {
            try JSONEncoder().encode(map).write(to: url, options: [.atomic])
        } catch {
            logger.error("Failed to adopt session index entries: \(error.localizedDescription)")
        }
    }

    private nonisolated static func createDirectoryIfNeeded(hostID: UUID?, storage: HostStorage, logger: AppLogger) {
        do {
            try FileManager.default.createDirectory(
                at: storage.directory(for: .target(hostID: hostID)),
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Failed to create session index directory: \(error.localizedDescription)")
        }
    }

    func record(sessionID: String, conversationID: UUID) {
        loadIfNeeded()
        if map[sessionID] != conversationID {
            map[sessionID] = conversationID
            needsSave = true
        }
        if needsSave { persist() }
    }

    func conversationID(for sessionID: String) -> UUID? {
        loadIfNeeded()
        return map[sessionID]
    }

    func remove(sessionID: String) {
        loadIfNeeded()
        if map.removeValue(forKey: sessionID) != nil { needsSave = true }
        if needsSave { persist() }
    }

    // Actor construction is synchronous on its caller; disk work belongs here.
    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        do { map = try Self.loadIndex(from: fileURL) }
        catch { logger.error("Failed to load session index: \(error.localizedDescription)") }
        hasLoaded = true
    }

}

extension ConversationIndex {
    nonisolated static func loadIndex(from url: URL) throws -> [String: UUID] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode([String: UUID].self, from: data)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(map)
            try data.write(to: fileURL, options: [.atomic])
            needsSave = false
        } catch {
            logger.error("Failed to persist session index: \(error.localizedDescription)")
        }
    }
}
