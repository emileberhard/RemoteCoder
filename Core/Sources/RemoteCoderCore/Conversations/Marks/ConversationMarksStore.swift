import Foundation
import OSLog

protocol ConversationMarksPersistence: Actor {
    func load() async -> ConversationMarksStore.Loaded
    func save(_ replica: ConversationMarksReplica) async -> Bool
}

actor ConversationMarksStore: ConversationMarksPersistence {
    static let fileName = "conversation-marks.v2.json"
    private static let legacyFileName = "conversation-marks.json"

    private let fileURL: URL
    private let legacyURL: URL
    private let legacyAttentionURL: URL
    private let logger = Logger(subsystem: "RemoteCoder", category: "ConversationMarksStore")

    init(directory: URL) {
        fileURL = directory.appending(path: Self.fileName)
        legacyURL = directory.appending(path: Self.legacyFileName)
        legacyAttentionURL = directory.appending(path: "conversation-attention.json")
    }

    nonisolated static func storedFile(in directory: URL) -> URL? {
        [fileName, legacyFileName].map { directory.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    enum Loaded: Sendable {
        case missing
        case stored(ConversationMarksReplica)
        case unavailable
    }

    func load() -> Loaded {
        try? FileManager.default.removeItem(at: legacyAttentionURL)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return importLegacy()
        } catch {
            logger.error("conversation marks unavailable: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
        do {
            var replica = try JSONDecoder().decode(ConversationMarksReplica.self, from: data)
            let before = replica
            replica.retireDefaultScope()
            if replica != before, !save(replica) { return .unavailable }
            return .stored(replica)
        } catch {
            logger.error("conversation marks undecodable, setting them aside: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try UndecodableStoreRecovery.setAside(fileURL)
        } catch {
            logger.error("failed to set aside conversation marks: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
        return .missing
    }

    private func importLegacy() -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: legacyURL)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            logger.error("legacy conversation marks unavailable: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
        var replica: ConversationMarksReplica
        do {
            replica = try JSONDecoder().decode(ConversationMarksReplica.self, from: data)
        } catch {
            logger.error("legacy conversation marks undecodable, starting fresh: \(error.localizedDescription, privacy: .public)")
            return .missing
        }
        replica.retireDefaultScope()
        guard save(replica) else { return .unavailable }
        return .stored(replica)
    }

    @discardableResult
    func save(_ replica: ConversationMarksReplica) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(replica).write(to: fileURL, options: .atomic)
            return true
        } catch {
            logger.error("failed to persist conversation marks: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

@MainActor
final class ConversationMarksWriter {
    private let store: any ConversationMarksPersistence
    private var latest: ConversationMarksReplica?
    private var revision: UInt64 = 0
    private var savedRevision: UInt64 = 0
    private var writing: Task<Bool, Never>?

    init(store: any ConversationMarksPersistence) {
        self.store = store
    }

    func replace(_ replica: ConversationMarksReplica) {
        latest = replica
        revision &+= 1
        _ = startWriting()
    }

    func flush() async -> Bool {
        _ = await writing?.value
        while savedRevision != revision {
            guard await startWriting().value else { return false }
        }
        return true
    }

    private func startWriting() -> Task<Bool, Never> {
        if let writing { return writing }
        let task = Task { await saveLatest() }
        writing = task
        return task
    }

    private func saveLatest() async -> Bool {
        defer { writing = nil }
        while savedRevision != revision {
            guard let latest else { preconditionFailure("Dirty marks have no replica") }
            let capturedRevision = revision
            guard await store.save(latest) else { return false }
            savedRevision = capturedRevision
        }
        return true
    }
}
