import Foundation
import SQLite3
import Testing
@testable import RemoteCoderCore

struct CheckpointDatabaseTests {

    @Test func aBlockedWALCheckpointReportsBusyAndCanBeRetriedWithoutChangingRecords() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "checkpoint.sqlite")
        let database = try CheckpointDatabase(url: file, access: .persistence)
        _ = try database.replace([.init(key: "live", data: Data("Original".utf8))], retaining: ["live"])
        var reader: OpaquePointer?
        guard sqlite3_open_v2(file.path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(reader) }
        guard sqlite3_exec(reader, "BEGIN; SELECT * FROM records", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        let changed = Data("Changed durable record".utf8)
        _ = try database.replace([.init(key: "live", data: changed)], retaining: ["live"])
        do {
            try database.checkpointWAL()
            Issue.record("A reader still holds the old WAL snapshot")
        } catch let error as CheckpointDatabase.Failure {
            #expect(error.code == SQLITE_BUSY)
        }
        #expect(try database.read(key: "live") == changed)
        guard sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        try database.checkpointWAL()
        #expect(try Data(contentsOf: URL(fileURLWithPath: file.path + "-wal")).isEmpty)
        #expect(try database.read(key: "live") == changed)
    }

    @Test func opaqueRecordIdentitiesKeepTheirEntireUTF8Contents() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try CheckpointDatabase(url: directory.appending(path: "checkpoint.sqlite"), access: .persistence)
        let keys: Set<String> = ["turn:å\u{0}one", "turn:å\u{0}two"]
        _ = try database.replace(keys.map { .init(key: $0, data: Data($0.utf8)) }, retaining: keys)
        #expect(Set(try database.read().map(\.key)) == keys)
        _ = try database.replace([], retaining: ["turn:å\u{0}two"])
        #expect(try database.read().map(\.key) == ["turn:å\u{0}two"])
    }

    @Test func aLargeAppendedRecordWritesOnlyItsNewChunksAndTrimsRemovedData() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try CheckpointDatabase(url: directory.appending(path: "checkpoint.sqlite"), access: .persistence)
        let original = Data(repeating: 65, count: 1_024 * 1_024)
        _ = try database.replace([.init(key: "live", data: original)], retaining: ["live"])
        let suffix = Data(repeating: 66, count: 4_096)
        let appended = original + suffix
        #expect(try database.replace([.init(key: "live", data: appended)], retaining: ["live"]).bytes == suffix.count)
        #expect(try database.read().first?.data == appended)
        let shortened = Data(original.prefix(5_000))
        _ = try database.replace([.init(key: "live", data: shortened)], retaining: ["live"])
        #expect(try database.read().first?.data == shortened)
        _ = try database.replace([], retaining: [])
        #expect(try database.read().isEmpty)
    }

    @Test func aFailedTransactionRetainsEveryPreviousRecordAndCanBeRetried() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "checkpoint.sqlite")
        let database = try CheckpointDatabase(url: file, access: .persistence)
        let original = Data("Original tail".utf8)
        _ = try database.replace([.init(key: "live", data: original)], retaining: ["live"])
        try execute("CREATE TRIGGER reject_record BEFORE INSERT ON records WHEN NEW.key='reject' BEGIN SELECT RAISE(ABORT, 'Rejected fixture'); END", file: file)
        let changed: [CheckpointDatabase.Record] = [.init(key: "live", data: Data("Changed tail".utf8)), .init(key: "reject", data: Data("Rejected record".utf8))]
        #expect(throws: (any Error).self) { _ = try database.replace(changed, retaining: ["live", "reject"]) }
        let retained = try database.read()
        #expect(retained.count == 1)
        #expect(retained.first?.data == original)
        try execute("DROP TRIGGER reject_record", file: file)
        _ = try database.replace(changed, retaining: ["live", "reject"])
        #expect(try database.read().count == 2)
    }

    @Test func anUnsupportedSchemaIsRejectedWithoutChangingItsJournalOrContents() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "checkpoint.sqlite")
        try execute("CREATE TABLE future(payload TEXT); INSERT INTO future VALUES('Unknown durable data'); PRAGMA user_version=2", file: file)
        let before = try FileIdentity(file)
        #expect(throws: (any Error).self) { _ = try CheckpointDatabase(url: file, access: .persistence) }
        #expect(try FileIdentity(file) == before)
        #expect(!FileManager.default.fileExists(atPath: file.path + "-wal"))
    }

    @Test func inspectionReadsAClosedWALDatabaseWhoseSidecarsWereRemoved() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "checkpoint.sqlite")
        do {
            let database = try CheckpointDatabase(url: file, access: .persistence)
            _ = try database.replace([.init(key: "header", data: Data("Saved header".utf8))], retaining: ["header"])
        }
        #expect(!FileManager.default.fileExists(atPath: file.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: file.path + "-shm"))
        do {
            let inspection = try CheckpointDatabase(url: file, access: .inspection)
            #expect(try inspection.readHeader() == Data("Saved header".utf8))
        }
        #expect(!FileManager.default.fileExists(atPath: file.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: file.path + "-shm"))
    }

    @Test func anInspectionOfASidecarFreeDatabaseRejectsAWriteThatLandedDuringIt() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "checkpoint.sqlite")
        do {
            let database = try CheckpointDatabase(url: file, access: .persistence)
            _ = try database.replace([.init(key: "header", data: Data("Saved header".utf8))], retaining: ["header"])
        }
        let inspection = try CheckpointDatabase(url: file, access: .inspection)
        do {
            let writer = try CheckpointDatabase(url: file, access: .persistence)
            _ = try writer.replace([.init(key: "header", data: Data("Newer header".utf8))], retaining: ["header"])
        }
        #expect(!FileManager.default.fileExists(atPath: file.path + "-wal"))
        #expect(throws: CheckpointDatabase.Failure.self) { _ = try inspection.readHeader() }
    }

    @Test func inspectionNeverCreatesAMissingDatabase() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "checkpoint.sqlite")
        #expect(throws: CheckpointDatabase.Failure.self) { _ = try CheckpointDatabase(url: file, access: .inspection) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    private func execute(_ sql: String, file: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(file.path, &connection) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}
