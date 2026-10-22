import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct ComposerCommandTests {
    @Test func compactInNewChatDoesNotCreateAConversation() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let screen = try #require(fixture.workspace.selectedScreen)
        let target = screen.executionTarget
        #expect(await screen.prepareDraft())
        let conversationID = screen.currentConversationID
        screen.input = "/compact"

        #expect(screen.composerSendState == .blocked)
        #expect(await fixture.workspace.send(from: screen) == false)
        #expect(fixture.workspace.selectedScreen === screen)
        #expect(screen.executionTarget == target)
        #expect(screen.currentConversationID == conversationID)
        #expect(screen.activeSessionID == nil)
        #expect(screen.input == "/compact")
    }

    @Test func compactRequiresKnownIdleActivityOnItsExactThread() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let screen = try #require(fixture.workspace.selectedScreen)
        var thread = try fixture.thread("compact-existing", updatedAt: 100)
        thread.model = CodexModelFixtures.solID
        thread.reasoningEffort = .medium
        screen.resumeConversation(thread)
        #expect(await waitUntil { screen.loadingTranscriptID == nil })
        let session = await screen.target.conversations.session(conversationID: screen.currentConversationID, threadID: thread.id)
        screen.observe(session)
        #expect(await screen.prepareDraft())
        screen.input = "/compact"

        screen.target.conversationActivity = ConversationActivity()
        #expect(screen.composerSendState == .blocked)
        #expect(await fixture.workspace.send(from: screen) == false)
        #expect(screen.input == "/compact")

        screen.target.conversationActivity = activity(thread: thread.id, state: .idle)
        #expect(screen.compactionUnavailableReason == nil)
        #expect(screen.composerSendState == .send)

        screen.target.conversationActivity = activity(thread: thread.id, state: .working)
        #expect(screen.composerSendState == .blocked)
        #expect(await fixture.workspace.send(from: screen) == false)
        #expect(fixture.workspace.selectedScreen === screen)
        #expect(screen.activeSessionID == thread.id)
        #expect(screen.input == "/compact")
    }

    @Test func canonicalCompactionBlocksMessagesAndKeepsNewerDraftEdits() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let screen = try #require(fixture.workspace.selectedScreen)
        var thread = try fixture.thread("compact-draft", updatedAt: 100)
        thread.model = CodexModelFixtures.solID
        thread.reasoningEffort = .medium
        screen.resumeConversation(thread)
        #expect(await waitUntil { screen.loadingTranscriptID == nil })
        let session = await screen.target.conversations.session(conversationID: screen.currentConversationID, threadID: thread.id)
        screen.observe(session)
        screen.target.conversationActivity = activity(thread: thread.id, state: .idle)
        let request = UUID()
        #expect(await session.beginCompaction(request))
        await screen.publish(await session.snapshot())
        #expect(await screen.prepareDraft())
        screen.input = "Keep this newer edit"
        #expect(screen.composerSendState == .blocked)
        #expect(await screen.send() == false)
        #expect(screen.input == "Keep this newer edit")

        await session.compactionRequestFailed(request, message: "Rejected", deliveryUncertain: false)
        await screen.publish(await session.snapshot())
        #expect(screen.input == "Keep this newer edit")
        #expect(screen.compaction?.phase == .failed("Rejected"))
        #expect(screen.composerSendState == .send)
    }

    private func activity(thread: String, state: CodexGatewayDaemon.ActivityState) -> ConversationActivity {
        ConversationActivity(snapshot: .init(epoch: "commands", revision: 1, activeTurns: [],
            coverage: .init(codex: true, claude: true),
            externalActivity: .init(sessions: [.init(threadId: thread, state: state, owner: nil)],
                                    claudeAvailable: true, codexAvailable: true), agentOwners: [:]))
    }
}
