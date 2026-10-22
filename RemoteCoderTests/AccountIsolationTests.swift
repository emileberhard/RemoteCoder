import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct AccountIsolationTests {
    @Test func oldGatewayEnrollmentsCannotCreateAdditionalContextsOrQuota() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let identity = ProviderAccountIdentity(key: "one-account", email: "person@example.test", workspace: nil)
        func snapshot(_ id: String, isDefault: Bool, percent: Double) -> ProviderAccountSnapshot {
            ProviderAccountSnapshot(id: id, provider: .codex, label: "Main", enabled: true, generation: 1,
                isDefault: isDefault, identity: identity, plan: "pro", state: .ready,
                windows: [.init(id: "weekly", label: "Weekly", durationMinutes: 10080, usedPercent: percent, resetsAt: nil, model: nil)],
                observedAt: 100, stale: false, error: nil, activeTurns: 0, incomingCallRoutingId: nil)
        }
        let current = snapshot("default-codex", isDefault: true, percent: 41)
        let retired = snapshot(UUID().uuidString, isDefault: false, percent: 99)
        try await AccountDirectoryStore(storage: fixture.temporaryStorage.storage).save(
            .init(schemaVersion: 2, accounts: [current, retired], refreshing: false), hostID: fixture.mini.id)
        await fixture.workspace.accountDirectory.restore()
        #expect(fixture.workspace.models.count == fixture.workspace.settings.hosts.count)
        let group = try #require(fixture.workspace.codexAccount)
        #expect(group.hosts.count == 1)
        #expect(group.sample.id == "default-codex")
        #expect(group.sample.windows.first?.usedPercent == 41)
    }

    @Test func notificationOpensItsHostAndQuestion() async throws {
        let fixture = await WorkspaceFixture(loadConversationHeader: { _, id in
            let data = Data("""
                {"id":"\(id)","preview":"Test","modelProvider":"test","createdAt":0,"updatedAt":1,
                 "cwd":"/repo","cliVersion":"test","source":"appServer","status":{"type":"notLoaded"},"ephemeral":false,"turns":[]}
                """.utf8)
            return ConversationHeader(try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: data))
        })
        defer { await fixture.cleanUp() }
        let notification = TaskCompletionNotificationPayload(eventID: "question:shared", source: .codex,
            outcome: nil, conversationID: nil, sessionID: "shared", hostID: fixture.book.id,
            promptPreview: "Question", messagePreview: "Choose", workingDirectory: nil,
            createdAtUnixSeconds: 1_790_000_000, questionItemID: "q")
        await fixture.workspace.handleCompletionNotificationTap(payload: notification)
        #expect(fixture.workspace.selectedHostID == fixture.book.id)
        #expect(fixture.workspace.selectedScreen?.activeSessionID == "shared")
        #expect(fixture.workspace.selectedScreen?.questionFocusRequest?.itemID == "q")
        #expect(fixture.workspace.notificationRoutingError == nil)
    }

    @Test(arguments: [false, true])
    func changingProviderKeepsTheSameDraftAndFastPreference(fastMode: Bool) async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        await fixture.restoreCachedModels()
        let workspace = fixture.workspace
        let source = try #require(workspace.selectedScreen)
        #expect(await source.prepareDraft())
        source.selectModel(try CodexModelFixtures.option(CodexModelFixtures.astraID), for: nil)
        source.selectFastMode(fastMode, for: nil)
        source.input = "Keep this prompt"
        let attachment = ComposerAttachment.text("Keep this attachment")
        source.composerAttachments = [attachment]
        workspace.selectModel(ClaudeModelCatalog.defaultModel)
        #expect(workspace.selectedScreen === source)
        #expect(source.currentAgentProvider == .claude)
        #expect(source.composerDocument?.content == .init(runs: [.text("Keep this prompt"), .paste(.init(id: attachment.id, text: "Keep this attachment"))]))
        #expect(source.composerAttachments.isEmpty)
        #expect(source.fastModeSelection == fastMode)
        workspace.selectModel(try CodexModelFixtures.option(CodexModelFixtures.astraID))
        #expect(source.fastModeEnabled == fastMode)
    }
}
