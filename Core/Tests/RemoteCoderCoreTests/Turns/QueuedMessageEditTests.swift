import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
@Suite(.serialized)
struct QueuedMessageEditTests {
    @Test func anAcknowledgedDeleteSavesTheTextAfterWhatWasTypedBeforeDroppingTheRow() async throws {
        let fixture = try await StopFixture.open()
        fixture.drafts.setContent(.init(runs: [.text("Typed")]), in: fixture.draft)
        let queued = try await queue("Later", in: fixture)

        fixture.dispatcher.editQueued(messageID: queued.id, conversationID: fixture.conversationID, threadID: fixture.turn.threadID,
                                      content: try #require(queued.restorableComposerContent), into: fixture.draft)
        await fixture.dispatcher.drain()

        #expect(fixture.drafts.document(for: fixture.draft).content.expandedText == "Typed\n\nLater")
        #expect(await !fixture.session.snapshot().messages.contains { $0.id == queued.id })
        let saved = try await ComposerDraftPersistence.open(directory: fixture.temporary.storage.root.appending(path: "drafts"))
            .load(destination: ComposerDraftStore.Destination.thread(fixture.turn.threadID).key)
        #expect(saved?.snapshot.content.expandedText == "Typed\n\nLater")
        let checkpoint = try await coldCheckpoint(fixture)
        #expect(checkpoint?.submissions[queued.id] == nil)
        await fixture.close()
    }

    @Test func anEntryThatAlreadyStartedLeavesTheComposerAndReconcilesTheQueue() async throws {
        let fixture = try await StopFixture.open()
        fixture.drafts.setContent(.init(runs: [.text("Typed")]), in: fixture.draft)
        let queued = try await queue("Later", in: fixture)
        await fixture.socket.setDeletes(false)

        fixture.dispatcher.editQueued(messageID: queued.id, conversationID: fixture.conversationID, threadID: fixture.turn.threadID,
                                      content: try #require(queued.restorableComposerContent), into: fixture.draft)
        await fixture.dispatcher.drain()

        #expect(fixture.drafts.document(for: fixture.draft).content.expandedText == "Typed")
        #expect(await fixture.socket.count("thread/queue/list") == 1)
        let row = await fixture.session.snapshot().messages.first { $0.id == queued.id }
        #expect(row?.text == "Later")
        await fixture.close()
    }

    @Test func aDraftThatCannotTakeTheTextLeavesANotSentRowHoldingIt() async throws {
        let fixture = try await StopFixture.open()
        let queued = try await queue("Later", in: fixture)
        _ = await fixture.drafts.retire()

        fixture.dispatcher.editQueued(messageID: queued.id, conversationID: fixture.conversationID, threadID: fixture.turn.threadID,
                                      content: try #require(queued.restorableComposerContent), into: fixture.draft)
        await fixture.dispatcher.drain()

        let row = await fixture.session.snapshot().messages.first { $0.id == queued.id }
        #expect(row?.delivery == .notSent)
        #expect(row?.text == "Later")
        let saved = try #require(try await coldCheckpoint(fixture)?.submissions[queued.id])
        #expect(saved.status == .failed)
        #expect(saved.message.text == "Later")
        await fixture.close()
    }

    @Test func aKillAfterTheDeleteBeforeTheDraftSaveRestoresTheTextAsAnUnconfirmedRow() async throws {
        let fixture = try await StopFixture.open()
        let queued = try await queue("Later", in: fixture)
        try await fixture.session.flush()

        let cold = ConversationCheckpointStore(hostID: fixture.hostID, storage: fixture.temporary.storage,
                                               primaryBudgetBytes: 512 * 1_024 * 1_024)
        let restored = await ConversationSession.make(conversationID: fixture.conversationID,
                                                      threadID: fixture.turn.threadID, checkpoints: cold)
        try await restored.restore()
        let read = await restored.beginQueueRead()
        await restored.applyQueue(CodexAppServerV2.QueueListing(entries: [], hold: nil), read: read, threadIsIdle: true)

        let row = await restored.snapshot().messages.first { $0.id == queued.id }
        #expect(row?.delivery == .unconfirmed)
        #expect(row?.text == "Later")
        await fixture.close()
    }

    private func queue(_ text: String, in fixture: StopFixture) async throws -> ChatMessage {
        let message = ChatMessage(role: .user, text: text)
        _ = try await fixture.session.submitToQueue(message, input: text)
        try await fixture.session.persistSubmission(message.id)
        await fixture.session.queued(message.id, submission: .init(id: "queued-\(message.id)", clientUserMessageId: message.id.uuidString))
        return message
    }

    private func coldCheckpoint(_ fixture: StopFixture) async throws -> ConversationState.Checkpoint? {
        let cold = ConversationCheckpointStore(hostID: fixture.hostID, storage: fixture.temporary.storage,
                                               primaryBudgetBytes: 512 * 1_024 * 1_024)
        return try await cold.load(fixture.conversationID, threadID: fixture.turn.threadID)
    }
}
