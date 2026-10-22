import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationMarksWriterTests {
    @Test @MainActor func flushReportsFailureAndRetriesTheLatestReplicaWithoutLosingPendingMarks() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: ConversationMarksStore.fileName)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let store = ConversationMarksStore(directory: directory)
        let writer = ConversationMarksWriter(store: store)
        var replica = ConversationMarksReplica()
        replica.retireDefaultScope()
        for index in 0..<1_000 {
            replica.record(.pin(threadID: "chat", name: "Pin \(index)"))
            writer.replace(replica)
        }
        #expect(await writer.flush() == false)
        replica.record(.markUnread(threadID: "chat"))
        writer.replace(replica)
        #expect(await writer.flush() == false)
        try FileManager.default.removeItem(at: file)
        #expect(await writer.flush())
        guard case .stored(let persisted) = await store.load() else {
            Issue.record("The current replica must be readable after retry")
            return
        }
        #expect(persisted == replica)
        #expect(persisted.effective.pinName(for: "chat") == "Pin 999")
        #expect(persisted.pending.last?.change == .markUnread(threadID: "chat"))
    }
}
