import Foundation
import OSLog

actor RealtimeVoiceHistoryStore {

    struct Entry: Codable, Sendable {
        let role: RealtimeVoiceRole
        let text: String
        let date: Date
    }

    private static let saveDelay: Duration = .seconds(5)

    private let fileURL: URL
    private let logger = AppLogger(category: "RealtimeVoiceHistoryStore")
    private var entriesByThreadID: [String: [Entry]] = [:]
    private var hasLoaded = false
    private var loadFailed = false
    private var hasUnsavedChanges = false
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil, hostID: UUID? = nil, storage: HostStorage = .live) {
        let resolvedURL: URL
        if let fileURL {
            resolvedURL = fileURL
        } else {
            let directory = storage.directory(for: .target(hostID: hostID))
            resolvedURL = directory.appendingPathComponent(
                "realtime-voice-history.json",
                isDirectory: false
            )
        }

        self.fileURL = resolvedURL
    }

    func entries(for threadID: String) -> [Entry] {
        loadIfNeeded()
        return entriesByThreadID[threadID] ?? []
    }

    func append(role: RealtimeVoiceRole, text: String, date: Date, threadID: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        loadIfNeeded()
        guard hasLoaded else { return }

        var entries = entriesByThreadID[threadID] ?? []
        if let last = entries.last,
           last.role == role,
           last.text == normalized {
            return
        }
        entries.append(Entry(role: role, text: normalized, date: date))
        if entries.count > 512 {
            entries.removeFirst(entries.count - 512)
        }
        entriesByThreadID[threadID] = entries
        hasUnsavedChanges = true
        scheduleSave()
    }

    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        return persistIfNeeded()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let store = self
        saveTask = Task {
            do { try await Task.sleep(for: Self.saveDelay) } catch { return }
            await store.finishScheduledSave()
        }
    }

    private func finishScheduledSave() {
        guard !Task.isCancelled else { return }
        saveTask = nil
        persistIfNeeded()
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            hasLoaded = true
            loadFailed = false
            return
        } catch {
            loadFailed = true
            logger.error("Realtime voice history unreadable; leaving the file untouched: \(error.localizedDescription)")
            return
        }
        do {
            entriesByThreadID = try JSONDecoder().decode([String: [Entry]].self, from: data)
            hasLoaded = true
            loadFailed = false
            if pruneOldestSessions() {
                hasUnsavedChanges = true
                scheduleSave()
            }
            return
        } catch {
            loadFailed = true
            logger.error("Realtime voice history undecodable; setting it aside: \(error.localizedDescription)")
        }
        do {
            try UndecodableStoreRecovery.setAside(fileURL)
            hasLoaded = true
            loadFailed = false
        } catch {
            logger.error("Failed to set aside undecodable realtime voice history: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func persistIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return !loadFailed }
        _ = pruneOldestSessions()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entriesByThreadID)
            try data.write(to: fileURL, options: [.atomic])
            hasUnsavedChanges = false
            return true
        } catch {
            logger.error("Failed to persist realtime voice history: \(error.localizedDescription)")
            return false
        }
    }

    private func pruneOldestSessions() -> Bool {
        let excess = entriesByThreadID.count - 64
        guard excess > 0 else { return false }
        let oldest = entriesByThreadID.map { (id: $0.key, newest: $0.value.lazy.map(\.date).max()) }
            .sorted { left, right in
                switch (left.newest, right.newest) {
                case (nil, nil): left.id < right.id
                case (nil, _): true
                case (_, nil): false
                case (let a?, let b?): a == b ? left.id < right.id : a < b
                }
            }
        for session in oldest.prefix(excess) { entriesByThreadID.removeValue(forKey: session.id) }
        return true
    }
}
