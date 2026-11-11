import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
@Suite(.serialized)
struct EditAsForkDispatchTests {
    private let point = NewChatSetup.ForkPoint(threadID: "thread", lastTurnID: "turn-1")

    @Test func aForkPointForksTheSourceInsteadOfStartingAThreadAndLeavesTheSourceSessionAlone() async throws {
        let fixture = try await StopFixture.open()
        await fixture.socket.setStartedThread(try ThreadFixture.wire("forked", updatedAt: 1), model: nil, effort: nil)
        let source = await fixture.session.snapshot()
        let edit = try await editDraft("Edited", in: fixture)

        fixture.dispatcher.startTurn(edit.submission, in: .fork(point))
        await fixture.dispatcher.drain()

        let fork = try await fixture.socket.request("thread/fork")
        #expect(fork.params?.objectValue?["threadId"]?.stringValue == "thread")
        #expect(fork.params?.objectValue?["lastTurnId"]?.stringValue == "turn-1")
        #expect(await fixture.socket.count("thread/start") == 0)
        let turn = try await fixture.socket.request("turn/start")
        #expect(turn.params?.objectValue?["threadId"]?.stringValue == "forked")
        #expect(turn.params?.objectValue?["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "Edited")
        #expect(edit.draft.destination == ComposerDraftStore.Destination.thread("forked").key)
        #expect(fixture.createdThreadReads == ["forked"])
        let after = await fixture.session.snapshot()
        #expect(after.threadID == source.threadID)
        #expect(after.messages == source.messages)
        await fixture.close()
    }

    @Test func aRefusedForkLeavesTheMessageNotSentAndTheNextSendForksAgain() async throws {
        let fixture = try await StopFixture.open()
        await fixture.socket.setStartedThread(try ThreadFixture.wire("forked", updatedAt: 1), model: nil, effort: nil)
        await fixture.socket.setForks(false)
        let edit = try await editDraft("Edited", in: fixture)

        fixture.dispatcher.startTurn(edit.submission, in: .fork(point))
        await fixture.dispatcher.drain()

        let row = await edit.session.snapshot().messages.first { $0.id == edit.submission.userMessageID }
        #expect(row?.delivery == .notSent)
        #expect(await fixture.socket.count("thread/start") == 0)
        #expect(await fixture.socket.count("turn/start") == 0)
        #expect(fixture.createdThreadReads.isEmpty)
        let kept = try #require(edit.draft.newChat?.forkPoint)
        #expect(kept == point)

        await fixture.socket.setForks(true)
        let retry = ChatMessage(role: .user, text: "Edited again")
        _ = try await edit.session.submitDurably(retry, input: "Edited again")
        fixture.dispatcher.startTurn(.init(draft: edit.draft, conversationID: edit.conversationID, userMessageID: retry.id,
                                           input: "Edited again", interactionMode: .text, settings: fixture.settings),
                                     in: .fork(kept))
        await fixture.dispatcher.drain()

        #expect(try await fixture.socket.requests("thread/fork", count: 2).count == 2)
        let turn = try await fixture.socket.request("turn/start")
        #expect(turn.params?.objectValue?["threadId"]?.stringValue == "forked")
        #expect(await fixture.socket.count("thread/start") == 0)
        await fixture.close()
    }

    @Test func aNewThreadReadsItsHistoryOnlyOnceItsFirstTurnCompletes() async throws {
        let fixture = try await StopFixture.open()
        await fixture.socket.setStartedThread(try ThreadFixture.wire("fresh", updatedAt: 1), model: nil, effort: nil)
        let conversationID = UUID()
        let draft = try #require(await fixture.drafts.draft(for: .newChat(UUID())))
        let session = await fixture.conversations.session(conversationID: conversationID, threadID: nil)
        try await session.restore()
        let message = ChatMessage(role: .user, text: "Hello")
        _ = try await session.submitDurably(message, input: "Hello")

        fixture.dispatcher.startTurn(.init(draft: draft, conversationID: conversationID, userMessageID: message.id, input: "Hello",
                                           interactionMode: .text, settings: fixture.settings), in: .start)
        await fixture.dispatcher.drain()
        #expect(fixture.createdThreadReads.isEmpty)

        fixture.dispatcher.turnCompleted(threadID: "fresh", turnID: "successor")
        fixture.dispatcher.turnCompleted(threadID: "fresh", turnID: "successor")
        #expect(fixture.createdThreadReads == ["fresh"])
        await fixture.close()
    }

    private struct EditDraft {
        let conversationID: UUID
        let draft: ComposerDraft
        let session: ConversationSession
        let submission: TurnDispatcher.Submission
    }

    private func editDraft(_ text: String, in fixture: StopFixture) async throws -> EditDraft {
        let conversationID = UUID()
        let draft = try #require(await fixture.drafts.draft(for: .newChat(UUID())))
        fixture.drafts.setNewChatSetup(NewChatSetup(workingDirectory: "/repo", modelID: "gpt-6.1-sol", reasoning: .automatic,
                                                    fastMode: nil, forkPoint: point), in: draft)
        fixture.drafts.setText(text, in: draft)
        let outgoing = try #require(fixture.drafts.beginSending(draft))
        let session = await fixture.conversations.session(conversationID: conversationID, threadID: nil)
        try await session.restore()
        let message = ChatMessage(role: .user, text: text)
        _ = try await session.submitDurably(message, input: text)
        fixture.drafts.submitted(outgoing, conversationID: conversationID)
        return EditDraft(conversationID: conversationID, draft: draft, session: session,
                         submission: .init(draft: draft, conversationID: conversationID, userMessageID: message.id, input: text,
                                           interactionMode: .text, settings: fixture.settings))
    }
}
