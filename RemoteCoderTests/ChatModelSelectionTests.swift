import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct ChatModelSelectionTests {
    private typealias Fixtures = CodexModelFixtures

    @Test func selectingAModelDuringAnExistingRunningTurnKeepsTheConversation() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        await fixture.restoreCachedModels()
        let screen = try #require(fixture.workspace.selectedScreen)
        let thread = "running-model-change"
        screen.setActiveSessionID(thread)
        let active = CodexGatewayDaemon.ActiveTurn(threadId: thread, turnId: "turn-running",
            startedAtUnixSeconds: 100, startedAtSequence: nil, promptPreview: "Working", cwd: "/repo")
        screen.target.reconcileWithDaemonActiveTurns(.init(epoch: "epoch", revision: 1, activeTurns: [active], coverage: .init(codex: true, claude: true),
            externalActivity: .init(sessions: [], claudeAvailable: true, codexAvailable: true), agentOwners: [:]), observedAt: Date(timeIntervalSince1970: 100))
        #expect(screen.isCurrentConversationBusy)
        let option = try Fixtures.option(Fixtures.astraID)
        fixture.workspace.selectModel(option)
        #expect(screen.selectedModel?.id == option.id)
        #expect(screen.activeSessionID == thread)
    }

    @Test func restoringTheCachePublishesTheNewChatDefault() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        try fixture.selectColdHost()
        let screen = try #require(fixture.workspace.selectedScreen)
        #expect(screen.target.codexModels.catalog == nil)
        #expect(screen.selectedModel == nil)

        await fixture.restoreCachedModels()

        #expect(screen.selectedModel?.id == Fixtures.solID)
        #expect(screen.target.codexModels.hasFetched == false)
        #expect(fixture.workspace.modelOptions(for: screen).filter { $0.provider == .codex }.map(\.id)
            == [Fixtures.astraID, Fixtures.solID, Fixtures.lunaID, Fixtures.sparkID])
    }

    @Test func restoringTheCachePreservesAnExplicitProviderChoice() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let cold = try fixture.selectColdHost()
        fixture.defaults.set(ClaudeModelCatalog.fableModelID, forKey: NewChatDefaults.modelDefaultKey)
        let codex = try #require(fixture.workspace.startNewConversation(provider: .codex, preferredHostID: cold.hostID))
        #expect(codex.selectedModel == nil)
        #expect(codex.newChatModelUnavailableReason?.contains("Codex models haven't loaded") == true)

        await fixture.restoreCachedModels()

        #expect(codex.selectedModel?.id == Fixtures.solID)
        #expect(codex.currentAgentProvider == .codex)
        #expect(NewChatDefaults.preferredModelID(defaults: fixture.defaults) == ClaudeModelCatalog.fableModelID)
    }

    @Test func teardownCancelsTheUnfinishedCatalogRestoration() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        try fixture.selectColdHost()
        let target = try #require(fixture.workspace.selectedScreen).target
        #expect(target.codexModels.catalog == nil)

        fixture.workspace.teardown()
        #expect(target.isRetired)
        await target.retire()

        #expect(target.codexModels.catalog == nil)
    }

    @Test func restoredConversationsKeepHiddenAndMissingModels() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        fixture.workspace.modelPickerPreferences.show(only: [.low, .medium])

        var hidden = try fixture.thread("hidden-model", updatedAt: 100)
        hidden.model = Fixtures.reserveID
        hidden.reasoningEffort = .medium
        model.resumeConversation(hidden)
        #expect(await waitUntil { model.loadingTranscriptID == nil })
        let reserve = try Fixtures.option(Fixtures.reserveID)
        #expect(model.selectedModel == reserve)
        #expect(model.pickerModelOptions(for: reserve).map(\.id)
            == [Fixtures.astraID, Fixtures.solID, Fixtures.lunaID, Fixtures.sparkID, Fixtures.reserveID])

        var retired = try fixture.thread("retired-model", updatedAt: 101)
        retired.model = "gpt-retired"
        retired.reasoningEffort = .xhigh
        model.resumeConversation(retired)
        #expect(await waitUntil { model.loadingTranscriptID == nil })
        #expect(model.selectedModel?.id == "gpt-retired")
        #expect(model.selectedModel?.isListed == false)
        #expect(model.reasoningSelection == .effort(.xhigh))
        #expect(model.areConversationSettingsReady)
    }

    @Test func hidingOrFixingTheNewChatModelClampsToAVisibleModel() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        #expect(model.selectedModel?.id == Fixtures.solID)

        fixture.workspace.modelPickerPreferences.setModelVisible(false, for: try #require(Fixtures.catalog().entry(for: Fixtures.solID)))
        #expect(model.selectedModel?.id == Fixtures.astraID)
        #expect(fixture.workspace.modelOptions(for: model).map(\.id)
            == [Fixtures.astraID, Fixtures.lunaID, Fixtures.sparkID, "fable", "opus", "sonnet", "haiku"])

        fixture.defaults.set(Fixtures.reserveID, forKey: NewChatDefaults.modelDefaultKey)
        model.startNewConversation()
        #expect(model.selectedModel?.id == Fixtures.astraID)
        fixture.defaults.set(Fixtures.lunaID, forKey: NewChatDefaults.modelDefaultKey)
        model.startNewConversation()
        #expect(model.selectedModel?.id == Fixtures.lunaID)
    }

    @Test func switchingProviderAppliesItsDefaultWithoutRecordingIt() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        #expect(NewChatDefaults.preferredModelID(defaults: fixture.defaults) == nil)

        let claude = try #require(fixture.workspace.startNewConversation(provider: .claude, preferredHostID: fixture.mini.id))
        #expect(claude.selectedModel?.id == ClaudeModelCatalog.fableModelID)
        #expect(NewChatDefaults.preferredModelID(defaults: fixture.defaults) == nil)

        let codex = try #require(fixture.workspace.startNewConversation(provider: .codex, preferredHostID: fixture.mini.id))
        #expect(codex.selectedModel?.id == Fixtures.solID)
        #expect(NewChatDefaults.preferredModelID(defaults: fixture.defaults) == nil)

        fixture.workspace.selectModel(try Fixtures.option(Fixtures.lunaID))
        #expect(NewChatDefaults.preferredModelID(defaults: fixture.defaults) == Fixtures.lunaID)
    }

    @Test func claudeVisibilityUpdatesDraftsAcrossHostsAndKeepsExistingConversations() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let mini = try #require(fixture.workspace.startNewConversation(provider: .claude, preferredHostID: fixture.mini.id))
        let book = try #require(fixture.workspace.startNewConversation(provider: .claude, preferredHostID: fixture.book.id))
        let preferences = fixture.workspace.modelPickerPreferences

        preferences.setClaudeModelVisible(false, id: "fable")
        #expect(mini.selectedModel?.id == "opus")
        #expect(book.selectedModel?.id == "opus")
        #expect(NewChatDefaults.preferredModelID(defaults: fixture.defaults) == nil)

        var thread = try fixture.thread("claude_existing", updatedAt: 100)
        thread.model = "opus"
        thread.reasoningEffort = .medium
        mini.resumeConversation(thread)
        #expect(await waitUntil { mini.loadingTranscriptID == nil })
        #expect(mini.activeSessionID == thread.id)

        preferences.setClaudeModelVisible(false, id: "opus")
        #expect(book.selectedModel?.id == "sonnet")
        #expect(mini.selectedModel?.id == "opus")
        #expect(fixture.workspace.modelOptions(for: mini).map(\.id) == ["sonnet", "haiku", "opus"])
        #expect(fixture.workspace.newChatModelOptions(preferredHostID: fixture.mini.id)
            .filter { $0.provider == .claude }.map(\.id) == ["sonnet", "haiku"])
    }

    @Test func sendingWithoutAModelPreservesTheDraft() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        for entry in try Fixtures.catalog().entries { fixture.workspace.modelPickerPreferences.setModelVisible(false, for: entry) }
        #expect(model.selectedModel == nil)
        #expect(model.areConversationSettingsReady)
        #expect(model.newChatModelUnavailableReason == "No Codex models are shown. Choose models in Settings.")

        #expect(await model.prepareDraft())
        model.input = "pwd"
        #expect(await model.send() == false)
        #expect(model.composerSendState == .blocked)
        #expect(model.input == "pwd")

    }

    @Test(arguments: [false, true])
    func freshChatsUseTheConfiguredModelAfterViewingClaude(changeFolder: Bool) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        fixture.defaults.set(Fixtures.solID, forKey: NewChatDefaults.modelDefaultKey)
        let claude = try #require(fixture.workspace.startNewConversation(provider: .claude, preferredHostID: fixture.mini.id))
        #expect(claude.selectedModel?.provider == .claude)
        var thread = try fixture.thread("claude_existing", updatedAt: 100)
        thread.model = ClaudeModelCatalog.fableModelID
        claude.resumeConversation(thread)
        #expect(await waitUntil { claude.loadingTranscriptID == nil })
        #expect(claude.activeSessionID == thread.id)
        claude.updateWorkingDirectory("/Users/developer/ExampleLibrary")

        if changeFolder {
            fixture.workspace.selectWorkingDirectory("/Users/developer/RemoteCoder", on: claude,
                                                     ifStillShowing: claude.currentConversationID)
        } else {
            fixture.workspace.startNewConversation(onHostID: fixture.mini.id)
        }

        let fresh = try #require(fixture.workspace.selectedScreen)
        #expect(fresh.selectedModel?.id == Fixtures.solID)
        #expect(fresh.currentAgentProvider == .codex)
        #expect(fresh.workingDirectory == (changeFolder ? "/Users/developer/RemoteCoder" : "/Users/developer/ExampleLibrary"))
        #expect(NewChatDefaults.preferredModelID(defaults: fixture.defaults) == Fixtures.solID)
    }
}
