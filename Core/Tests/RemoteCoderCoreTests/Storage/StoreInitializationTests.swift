import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct StoreInitializationTests {
    @Test func sessionIndexConstructionDoesNotTouchDiskAndFirstUseLoadsExistingMappings() async throws {
        let hostID = UUID()
        let fixture = TemporaryHostStorage()
        defer { fixture.cleanUp() }
        let directory = fixture.storage.directory(for: .host(hostID))
        let index = ConversationIndex(hostID: hostID, storage: fixture.storage)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let savedID = UUID()
        let url = ConversationIndex.fileURL(hostID: hostID, storage: fixture.storage)
        try JSONEncoder().encode(["saved": savedID]).write(to: url)
        #expect(await index.conversationID(for: "saved") == savedID)
        let newID = UUID()
        await index.record(sessionID: "new", conversationID: newID)
        let restored = ConversationIndex(hostID: hostID, storage: fixture.storage)
        #expect(await restored.conversationID(for: "saved") == savedID)
        #expect(await restored.conversationID(for: "new") == newID)
    }

    @Test func unchangedSessionMappingsDoNotRewriteTheIndex() async throws {
        let hostID = UUID()
        let fixture = TemporaryHostStorage()
        defer { fixture.cleanUp() }
        let directory = fixture.storage.directory(for: .host(hostID))
        let index = ConversationIndex(hostID: hostID, storage: fixture.storage)
        let id = UUID()
        await index.record(sessionID: "thread", conversationID: id)
        let url = ConversationIndex.fileURL(hostID: hostID, storage: fixture.storage)
        let marker = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: url.path)
        await index.record(sessionID: "thread", conversationID: id)
        await index.remove(sessionID: "absent")
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(modified == marker)
        await index.remove(sessionID: "thread")
        let restored = ConversationIndex(hostID: hostID, storage: fixture.storage)
        #expect(await restored.conversationID(for: "thread") == nil)
    }

    @Test func anUnchangedRecordRetriesAPreviouslyFailedWrite() async throws {
        let hostID = UUID()
        let fixture = TemporaryHostStorage()
        defer { fixture.cleanUp() }
        let directory = fixture.storage.directory(for: .host(hostID))
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A file in place of the directory makes only this store's first save fail.
        try Data([0]).write(to: directory)
        let index = ConversationIndex(hostID: hostID, storage: fixture.storage)
        let id = UUID()
        await index.record(sessionID: "thread", conversationID: id)
        try FileManager.default.removeItem(at: directory)
        await index.record(sessionID: "thread", conversationID: id)
        let restored = ConversationIndex(hostID: hostID, storage: fixture.storage)
        #expect(await restored.conversationID(for: "thread") == id)
    }

    @Test func voiceHistoryIsLoadedAtFirstUseAndAppendPreservesOtherThreads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("voice.json")
        let store = RealtimeVoiceHistoryStore(fileURL: url)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = RealtimeVoiceHistoryStore.Entry(role: .user, text: "Existing voice context", date: .now)
        try JSONEncoder().encode(["saved": [saved]]).write(to: url)
        let appendedAt = Date(timeIntervalSince1970: 1_000)
        await store.append(role: .assistant, text: "New context", date: appendedAt, threadID: "new")
        #expect(await store.entries(for: "saved").first?.text == saved.text)
        await store.flush()
        let restored = RealtimeVoiceHistoryStore(fileURL: url)
        #expect(await restored.entries(for: "saved").first?.text == saved.text)
        let appended = await restored.entries(for: "new")
        #expect(appended.count == 1)
        #expect(appended.first?.role == .assistant)
        #expect(appended.first?.text == "New context")
        #expect(appended.first?.date == appendedAt)
    }
}
