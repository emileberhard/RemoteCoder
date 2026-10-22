import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct ComposerSettingsTests {
    @Test func modelSwitchRestoresOnlyManuallyRememberedReasoning() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let luna = try CodexModelFixtures.option(CodexModelFixtures.lunaID)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        model.selectModel(luna, for: nil)
        model.selectReasoning(.effort(.medium), for: nil)
        model.selectModel(astra, for: nil)
        model.selectReasoning(.effort(.high), for: nil)
        model.selectModel(luna, for: nil)
        #expect(model.reasoningSelection == .effort(.medium))
        model.selectModel(astra, for: nil)
        #expect(model.reasoningSelection == .effort(.high))
    }

    @Test func pendingSettingsAndFailuresStayWithTheirConversation() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let option = try CodexModelFixtures.option(CodexModelFixtures.lunaID)
        model.applyConversationSettings(ConversationSettingsUpdate(
            threadID: "failed-thread", model: option, reasoning: .effort(.medium),
            fastModeState: .selection(false)
        ))
        #expect(model.isUpdatingSettings(for: "failed-thread"))
        #expect(!model.isUpdatingSettings(for: "other-thread"))
        #expect(!model.isUpdatingSettings(for: nil))
        #expect(await waitUntil { !model.isUpdatingSettings(for: "failed-thread") })
        #expect(model.settingsUpdateError(for: "failed-thread") != nil)
        #expect(model.settingsUpdateError(for: "other-thread") == nil)
        model.startNewConversation()
        #expect(model.settingsUpdateError(for: model.activeSessionID) == nil)
        #expect(model.settingsUpdateError(for: "failed-thread") != nil)
    }

    @Test func testOpeningVoiceFromComposerPreservesTheVisibleConversation() async throws {
        let original = ChatMessage(
            role: .user,
            text: "Remember the garden and library discussion"
        )
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        await model.target.restoreCachedCodexModels()
        model.showPreview([original])
        _ = try #require(model.selectedModel)

        model.selectReasoning(.effort(.xhigh), for: nil)
        try model.prepareForVoiceModePresentation(startsFreshChat: false)

        #expect(model.messages.map(\.id) == [original.id])
        #expect(model.messages.map(\.text) == [original.text])
        #expect(model.reasoningSelection == .effort(.xhigh))
    }

    @Test func testVoiceIntentStartsAFreshChatOnTheNewChatDefaultModel() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        fixture.defaults.set(CodexModelFixtures.sparkID, forKey: NewChatDefaults.modelDefaultKey)
        fixture.defaults.set("effort-low", forKey: NewChatDefaults.reasoningDefaultKey)
        NewChatDefaults.setFastModeEnabled(true, defaults: fixture.defaults)
        let model = try #require(fixture.workspace.selectedScreen)
        await model.target.restoreCachedCodexModels()
        model.startNewConversation()
        model.showPreview([
            ChatMessage(role: .user, text: "old context"),
        ])

        try model.prepareForVoiceModePresentation(startsFreshChat: true)

        #expect(model.messages.isEmpty)
        #expect(model.selectedModel?.id == CodexModelFixtures.sparkID)
        #expect(model.reasoningSelection == .effort(.low))
        #expect(!model.fastModeEnabled)
    }

    @Test func existingVoiceConversationKeepsItsProjectDirectory() async {
        let fixture = TargetModelFixture()
        defer { await fixture.cleanUp() }
        let target = fixture.target
        await target.restoreCachedCodexModels()
        let model = target.makeScreen(newChat: UUID())
        model.updateWorkingDirectory("/Users/developer/RemoteCoder")
        await model.prepareVoiceModeWorkingDirectory(startsFreshChat: false)
        #expect(model.workingDirectory == "/Users/developer/RemoteCoder")
    }

    @Test func shortcutConfigurationAppliesWithoutChangingNewChatDefaults() async throws {
        let fixture = TargetModelFixture()
        defer { await fixture.cleanUp() }
        let temporary = fixture.temporaryStorage
        let target = fixture.target
        await target.restoreCachedCodexModels()
        let model = target.makeScreen(newChat: UUID())
        let defaultModel = model.target.newChatDefaultModel().model
        let preferredModelID = NewChatDefaults.preferredModelID(defaults: temporary.defaults)
        let defaultReasoning = NewChatDefaults.reasoningSelection(defaults: temporary.defaults)
        let defaultFastMode = NewChatDefaults.fastModeEnabled(defaults: temporary.defaults)
        let configuration = RemoteCoderVoiceConfiguration(
            modelID: ClaudeModelCatalog.fableModelID,
            reasoningSelectionID: "effort-xhigh",
            fastModeEnabled: false
        )

        try model.prepareForVoiceModePresentation(startsFreshChat: true, configuration: configuration)

        #expect(model.selectedModel?.id == ClaudeModelCatalog.fableModelID)
        #expect(model.reasoningSelection == .effort(.xhigh))
        #expect(!model.fastModeEnabled)
        #expect(NewChatDefaults.preferredModelID(defaults: temporary.defaults) == preferredModelID)
        #expect(NewChatDefaults.reasoningSelection(defaults: temporary.defaults) == defaultReasoning)
        #expect(NewChatDefaults.fastModeEnabled(defaults: temporary.defaults) == defaultFastMode)

        model.startNewConversation()
        #expect(model.selectedModel == defaultModel)
        #expect(model.reasoningSelection == defaultReasoning)
        #expect(model.fastModeEnabled == (defaultFastMode && defaultModel?.supportsFastMode == true))
    }
}
