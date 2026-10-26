import Foundation
import SQLite3

final class CheckpointDatabase {
    enum Access { case inspection, persistence }
    struct Record: Sendable {
        let key: String
        let data: Data
    }

    struct Replacement {
        let bytes: Int
        let chunking: Duration
        let sqlCommit: Duration
    }

    struct Failure: LocalizedError {
        let operation: String
        let code: Int32
        let detail: String
        var errorDescription: String? { "Checkpoint database \(operation) failed (\(code)): \(detail)" }
    }

    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date

        init(path: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date else {
                throw CocoaError(.fileReadUnknown)
            }
            self.size = size
            self.modified = modified
        }
    }

    private var connection: OpaquePointer?
    private var immutableSnapshot: (path: String, stamp: FileStamp)?
    private static let chunkBytes = 16 * 1_024
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, access: Access) throws {
        var opened: OpaquePointer?
        let result: Int32
        switch access {
        case .persistence:
            result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        case .inspection:
            var components = URLComponents()
            components.scheme = "file"
            components.path = url.path
            components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
            if !FileManager.default.fileExists(atPath: url.path + "-wal"), let stamp = try? FileStamp(path: url.path) {
                immutableSnapshot = (url.path, stamp)
                components.queryItems?.append(URLQueryItem(name: "immutable", value: "1"))
            }
            guard let uri = components.string else {
                throw Failure(operation: "open", code: SQLITE_CANTOPEN, detail: "The checkpoint path is not a valid file URI.")
            }
            result = sqlite3_open_v2(uri, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        }
        guard result == SQLITE_OK, let opened else {
            let detail = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open storage."
            if let opened { sqlite3_close(opened) }
            throw Failure(operation: "open", code: result, detail: detail)
        }
        connection = opened
        do {
            let version = try scalar("PRAGMA user_version")
            guard version == "0" || version == "1" else { throw CocoaError(.fileReadCorruptFile) }
            if version == "0" {
                guard try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table'") == "0" else { throw CocoaError(.fileReadCorruptFile) }
            }
            if access == .inspection { return }
            guard try scalar("PRAGMA journal_mode=WAL") == "wal" else { throw CocoaError(.fileWriteUnknown) }
            var persistsWAL: Int32 = 0
            try check(sqlite3_file_control(connection, "main", SQLITE_FCNTL_PERSIST_WAL, &persistsWAL), operation: "configure WAL lifetime")
            try execute("PRAGMA synchronous=FULL")
            if version == "0" {
                try execute("BEGIN IMMEDIATE; CREATE TABLE records (key TEXT NOT NULL, chunk INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(key, chunk)) WITHOUT ROWID; PRAGMA user_version=1; COMMIT")
            }
            try execute("PRAGMA wal_autocheckpoint=256")
            try execute("PRAGMA journal_size_limit=1048576")
        } catch {
            sqlite3_close(opened)
            connection = nil
            throw error
        }
    }

    deinit { if let connection { sqlite3_close(connection) } }

    func checkpointWAL() throws {
        try check(sqlite3_wal_checkpoint_v2(connection, "main", SQLITE_CHECKPOINT_TRUNCATE, nil, nil), operation: "truncate WAL")
    }

    func compact() throws {
        try execute("VACUUM")
    }

    func read() throws -> [Record] {
        try readRecords("SELECT key, chunk, payload FROM records ORDER BY key, chunk", key: nil)
    }

    func read(key: String) throws -> Data? {
        try readRecords("SELECT key, chunk, payload FROM records WHERE key=? ORDER BY chunk", key: key).first?.data
    }

    func payloadBytes() throws -> Int {
        guard let value = try scalar("SELECT COALESCE(SUM(length(CAST(payload AS BLOB))), 0) FROM records"),
              let bytes = Int(value) else { throw CocoaError(.fileReadCorruptFile) }
        try confirmSnapshotUnchanged()
        return bytes
    }

    func readHeader() throws -> Data? {
        try read(key: "header")
    }

    func readInvalidation() throws -> Data? {
        try read(key: "invalidation")
    }

    private func readRecords(_ sql: String, key boundKey: String?) throws -> [Record] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let boundKey { try bind(boundKey, to: statement, at: 1) }
        var result: [Record] = []
        var key: String?
        var payload = Data()
        var nextChunk = 0
        while try step(statement) {
            let current = try self.key(in: statement)
            if current != key {
                if let key { result.append(Record(key: key, data: payload)) }
                key = current
                payload = Data()
                nextChunk = 0
            }
            guard sqlite3_column_int64(statement, 1) == nextChunk else { throw CocoaError(.fileReadCorruptFile) }
            let count = Int(sqlite3_column_bytes(statement, 2))
            if count > 0 {
                guard let bytes = sqlite3_column_blob(statement, 2) else { throw CocoaError(.fileReadCorruptFile) }
                payload.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            }
            nextChunk += 1
        }
        if let key { result.append(Record(key: key, data: payload)) }
        try confirmSnapshotUnchanged()
        return result
    }

    private func confirmSnapshotUnchanged() throws {
        guard let immutableSnapshot else { return }
        guard !FileManager.default.fileExists(atPath: immutableSnapshot.path + "-wal"),
              try FileStamp(path: immutableSnapshot.path) == immutableSnapshot.stamp else {
            throw Failure(operation: "inspect", code: SQLITE_BUSY, detail: "The checkpoint changed while it was read.")
        }
    }

    func replace(_ records: [Record], retaining keys: Set<String>) throws -> Replacement {
        let started = ContinuousClock.now
        var chunking = Duration.zero
        try execute("BEGIN IMMEDIATE")
        do {
            let upsert = try prepare("INSERT INTO records(key, chunk, payload) VALUES(?, ?, ?) ON CONFLICT(key, chunk) DO UPDATE SET payload=excluded.payload WHERE payload != excluded.payload")
            defer { sqlite3_finalize(upsert) }
            let trim = try prepare("DELETE FROM records WHERE key=? AND chunk>=?")
            defer { sqlite3_finalize(trim) }
            var bytes = 0
            for record in records {
                let chunks = max(1, (record.data.count + Self.chunkBytes - 1) / Self.chunkBytes)
                for index in 0..<chunks {
                    sqlite3_reset(upsert)
                    sqlite3_clear_bindings(upsert)
                    try bind(record.key, to: upsert, at: 1)
                    try check(sqlite3_bind_int64(upsert, 2, Int64(index)), operation: "bind chunk")
                    let chunkStarted = ContinuousClock.now
                    let chunk = record.data.subdata(in: min(index * Self.chunkBytes, record.data.count)..<min((index + 1) * Self.chunkBytes, record.data.count))
                    chunking += chunkStarted.duration(to: .now)
                    try chunk.withUnsafeBytes { buffer in
                        try check(sqlite3_bind_blob(upsert, 3, buffer.baseAddress, Int32(chunk.count), Self.transient), operation: "bind payload")
                    }
                    _ = try step(upsert)
                    if sqlite3_changes(connection) > 0 { bytes += chunk.count }
                }
                sqlite3_reset(trim)
                sqlite3_clear_bindings(trim)
                try bind(record.key, to: trim, at: 1)
                try check(sqlite3_bind_int64(trim, 2, Int64(chunks)), operation: "bind trim")
                _ = try step(trim)
            }
            let existing = try prepare("SELECT DISTINCT key FROM records")
            var removed: [String] = []
            do {
                defer { sqlite3_finalize(existing) }
                while try step(existing) {
                    let key = try self.key(in: existing)
                    if !keys.contains(key) { removed.append(key) }
                }
            }
            let remove = try prepare("DELETE FROM records WHERE key=?")
            defer { sqlite3_finalize(remove) }
            for key in removed {
                sqlite3_reset(remove)
                sqlite3_clear_bindings(remove)
                try bind(key, to: remove, at: 1)
                _ = try step(remove)
            }
            try execute("COMMIT")
            return Replacement(bytes: bytes, chunking: chunking, sqlCommit: started.duration(to: .now) - chunking)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func scalar(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard try step(statement), let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func key(in statement: OpaquePointer) throws -> String {
        guard let raw = sqlite3_column_text(statement, 0),
              let value = String(bytes: UnsafeBufferPointer(start: raw, count: Int(sqlite3_column_bytes(statement, 0))), encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        guard let count = Int32(exactly: value.utf8.count) else { throw CocoaError(.fileWriteOutOfSpace) }
        try check(sqlite3_bind_text(statement, index, value, count, Self.transient), operation: "bind key")
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), operation: "prepare")
        guard let statement else { throw CocoaError(.fileReadCorruptFile) }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        try check(result == SQLITE_DONE ? SQLITE_OK : result, operation: "step")
        return false
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(connection, sql, nil, nil, nil), operation: "execute")
    }

    private func check(_ code: Int32, operation: String) throws {
        guard code == SQLITE_OK else { throw Failure(operation: operation, code: code, detail: String(cString: sqlite3_errmsg(connection))) }
    }
}
