import Foundation
import Testing

@testable import RemoteCoderCore

struct RealtimeVoiceHistoryStoreTests {


    @Test func aFailedReadCannotBeReportedAsASuccessfulFinalFlush() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "voice-history.json")
        let original = Data("{}".utf8)
        try original.write(to: file)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let store = RealtimeVoiceHistoryStore(fileURL: file)
        _ = await store.entries(for: "thread")
        #expect(!(await store.flush()))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
        _ = await store.entries(for: "thread")
        #expect(await store.flush())
    }

    @Test func finalFlushReportsFailureAndRetriesAdmittedVoiceText() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "voice-history.json")
        let store = RealtimeVoiceHistoryStore(fileURL: file)
        await store.append(role: .assistant, text: "Admitted voice text", date: .now, threadID: "thread")
        try Data("Blocking directory".utf8).write(to: directory)
        #expect(!(await store.flush()))
        try FileManager.default.removeItem(at: directory)
        #expect(await store.flush())
        let cold = RealtimeVoiceHistoryStore(fileURL: file)
        #expect(await cold.entries(for: "thread").map(\.text) == ["Admitted voice text"])
    }

    @Test func savingTheSixtyFifthSessionEvictsTheOldest() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "voice-history.json")
        let store = RealtimeVoiceHistoryStore(fileURL: fileURL)
        for index in 0..<65 {
            await store.append(role: .user, text: "Session \(index)",
                date: Date(timeIntervalSince1970: Double(index)), threadID: "thread-\(index)")
        }

        await store.flush()

        let saved = try JSONDecoder().decode([String: [RealtimeVoiceHistoryStore.Entry]].self,
            from: Data(contentsOf: fileURL))
        #expect(saved.count == 64)
        #expect(saved["thread-0"] == nil)
        #expect(saved["thread-64"]?.first?.text == "Session 64")
    }

    @Test func undecodableHistoryIsSetAsideInsteadOfOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("voice-history.json")
        let unreadable = Data("{\"thread-1\": [{\"role\": \"future\"}]}".utf8)
        try unreadable.write(to: fileURL)

        let store = RealtimeVoiceHistoryStore(fileURL: fileURL)
        #expect(await store.entries(for: "thread-1").isEmpty)
        await store.append(role: .user, text: "After recovery", date: .now, threadID: "thread-2")
        await store.flush()

        let setAside = directory.appendingPathComponent("voice-history.undecodable.json")
        #expect(try Data(contentsOf: setAside) == unreadable)
        let restored = RealtimeVoiceHistoryStore(fileURL: fileURL)
        #expect(await restored.entries(for: "thread-2").map(\.text) == ["After recovery"])
    }

    @Test func transcriptHistoryDropsConsecutiveDuplicates() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RealtimeVoiceHistoryStore(fileURL: fileURL)

        await store.append(role: .assistant, text: "Understood", date: .now, threadID: "thread-1")
        await store.append(role: .assistant, text: " Understood ", date: .now, threadID: "thread-1")

        let entries = await store.entries(for: "thread-1")
        #expect(entries.count == 1)
        await store.flush()
    }
}
