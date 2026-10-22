import AppIntents
import Foundation
import Observation
import Testing
@testable import RemoteCoder

@MainActor
struct VoiceModeIntentTests {
    @Test func coldVoicePreparationAwaitsTheCachedModel() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        try fixture.selectColdHost()
        let selected = try #require(fixture.workspace.selectedScreen)
        #expect(selected.target.codexModels.catalog == nil)
        HostPreferences.setRemoteHomePath("/workspace/home", hostID: selected.hostID, defaults: fixture.defaults)
        let configuration = RemoteCoderVoiceConfiguration(
            modelID: CodexModelFixtures.astraID, reasoningSelectionID: "effort-xhigh", fastModeEnabled: true
        )

        let prepared = try #require(await fixture.workspace.prepareVoiceCall(
            from: selected, startsFreshChat: true, configuration: configuration
        ))

        #expect(prepared === selected)
        #expect(prepared.selectedModel?.id == CodexModelFixtures.astraID)
        #expect(prepared.reasoningSelection == .effort(.xhigh))
        #expect(prepared.fastModeEnabled)
        #expect(prepared.workingDirectory == "/workspace/home")
        #expect(prepared.target.codexModels.hasFetched == false)
    }

    @Test func callRequestsOtherThanOneModelByAudioAreRejected() throws {
        let intent = RemoteCoderVoiceChatIntent()
        let opus = CodexModelEntity(option: ClaudeModelCatalog.defaultModel)
        intent.destination = .group([opus, opus])
        #expect(throws: VoiceModeConfigurationError.groupCall) { try intent.voiceConfiguration }

        intent.destination = .group([opus])
        #expect(try intent.voiceConfiguration.modelID == opus.id)

        intent.audioVisualMode = .video
        #expect(throws: VoiceModeConfigurationError.videoCall) { try intent.voiceConfiguration }
    }

    @Test func modelPickerListsTheVisibleCatalogOfTheNewChatDestination() async throws {
        let fixture = await WorkspaceFixture()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        try fixture.selectColdHost()
        #expect(fixture.workspace.codexModelCatalog.source?.service.catalog == nil)
        #expect(try await CodexModelQuery.entities(in: fixture.workspace).map(\.id) == [
            CodexModelEntity.appDefaultID, CodexModelFixtures.astraID, CodexModelFixtures.solID,
            CodexModelFixtures.lunaID, CodexModelFixtures.sparkID, "fable", "opus", "sonnet", "haiku",
        ])
    }

    @Test(arguments: [CodexModelEntity.appDefaultID, CodexModelFixtures.astraID])
    func coldIntentOptionsResolveTheCachedModel(modelID: String) async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        try fixture.selectColdHost()
        #expect(fixture.workspace.codexModelCatalog.source?.service.catalog == nil)
        let entity = CodexModelEntity.resolving(modelID, in: fixture.workspace)

        let model = try await CodexIntentModelCatalog.resolve(entity, in: fixture.workspace)

        #expect(model.id == (modelID == CodexModelEntity.appDefaultID ? CodexModelFixtures.solID : modelID))
        #expect(model.supportsFastMode)
        #expect(!fixture.workspace.modelPickerPreferences.reasoningEfforts(for: model).isEmpty)
        #expect(fixture.workspace.codexModelCatalog.source?.service.hasFetched == false)
    }

    @Test func changingTheDestinationCancelsItsPendingCatalogQuery() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        try fixture.selectColdHost()
        let original = try #require(fixture.workspace.codexModelCatalog.source?.service)
        let next = GatewayHostConfiguration(id: UUID(), name: "Cold destination", hostname: "127.0.0.1", port: 3,
                                            authToken: "fixture-token")
        try CodexModelFixtures.seed(hostID: next.id, storage: fixture.temporaryStorage.storage)
        let switchedWhileUnread = TestFlag()
        withObservationTracking {
            _ = original.catalog
        } onChange: {
            MainActor.assumeIsolated {
                fixture.workspace.settings.upsert(next)
                fixture.workspace.reconcileHosts()
                fixture.workspace.select(hostID: next.id)
                switchedWhileUnread.value = fixture.workspace.codexModelCatalog.source?.service.catalog == nil
            }
        }

        await #expect(throws: CancellationError.self) {
            _ = try await CodexModelQuery.entities(in: fixture.workspace)
        }

        #expect(switchedWhileUnread.value)
        #expect(fixture.workspace.selectedHostID == next.id)
        let entities = try await CodexModelQuery.entities(in: fixture.workspace)
        #expect(entities.contains { $0.id == CodexModelFixtures.astraID })
    }

    @Test(arguments: [CodexModelFixtures.astraID, CodexModelFixtures.sparkID, "fable"])
    func chosenModelAndExtraHighReachTheCall(modelID: String) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let option = try #require(fixture.workspace.configuredModel(id: modelID).model)
        let intent = RemoteCoderVoiceChatIntent()
        intent.destination = .model(CodexModelEntity.resolving(modelID, in: fixture.workspace))
        intent.reasoning = .xhigh
        intent.fastMode = .on

        #expect(try intent.voiceConfiguration
            == RemoteCoderVoiceConfiguration(modelID: modelID, reasoningSelectionID: "effort-xhigh", fastModeEnabled: true))
        try model.prepareForVoiceModePresentation(startsFreshChat: true, configuration: try intent.voiceConfiguration)

        #expect(model.selectedModel == option)
        #expect(model.reasoningSelection == .effort(.xhigh))
        #expect(model.fastModeEnabled == option.supportsFastMode)
    }

    @Test func unconfiguredShortcutDefersAppDefaultsToTheApp() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let intent = RemoteCoderVoiceChatIntent()
        intent.destination = .model(CodexModelEntity.appDefault(in: fixture.workspace))
        #expect(try intent.voiceConfiguration
            == RemoteCoderVoiceConfiguration(modelID: nil, reasoningSelectionID: nil, fastModeEnabled: NewChatDefaults.fastModeEnabled()))

        try model.prepareForVoiceModePresentation(startsFreshChat: true, configuration: try intent.voiceConfiguration)

        let expected = try #require(fixture.workspace.newChatDefaultModel().model)
        let reasoning = fixture.workspace.modelPickerPreferences.clamped(NewChatDefaults.reasoningSelection(), for: expected)
        #expect(expected.id == CodexModelFixtures.solID)
        #expect(model.selectedModel == expected)
        #expect(model.reasoningSelection == reasoning)
        #expect(model.fastModeEnabled == (NewChatDefaults.fastModeEnabled() && expected.supportsFastMode))
    }

    @Test func hiddenModelsStillRunWhileMissingModelsFail() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let entities = [CodexModelFixtures.reserveID, "gpt-retired"].map { CodexModelEntity.resolving($0, in: fixture.workspace) }
        #expect(entities.map(\.id) == [CodexModelFixtures.reserveID, "gpt-retired"])
        #expect(entities.map(\.name) == ["GPT-Reserve", "gpt-retired"])
        let intent = RemoteCoderVoiceChatIntent()
        intent.destination = .model(entities[0])
        intent.reasoning = .high
        intent.fastMode = .off
        try model.prepareForVoiceModePresentation(startsFreshChat: true, configuration: try intent.voiceConfiguration)
        #expect(model.selectedModel?.id == CodexModelFixtures.reserveID)

        intent.destination = .model(entities[1])
        #expect(throws: VoiceModeConfigurationError.modelNotOffered("gpt-retired")) {
            try model.prepareForVoiceModePresentation(startsFreshChat: true, configuration: try intent.voiceConfiguration)
        }
    }

    @Test(arguments: AgentProvider.allCases)
    func catalogChangesKeepAShortcutChosenHiddenModelUntilSettingsHideIt(provider: AgentProvider) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let catalog = try CodexModelFixtures.catalog()
        let reserve = try #require(catalog.entry(for: CodexModelFixtures.reserveID))
        let option = provider == .codex ? reserve.option : try #require(ClaudeModelCatalog.model(for: "opus"))
        func apply(_ visible: Bool) {
            switch provider {
            case .codex: fixture.workspace.modelPickerPreferences.setModelVisible(visible, for: reserve)
            case .claude: fixture.workspace.modelPickerPreferences.setClaudeModelVisible(visible, id: option.id)
            }
        }
        apply(false)
        let configuration = RemoteCoderVoiceConfiguration(
            modelID: option.id, reasoningSelectionID: "effort-high", fastModeEnabled: true
        )
        try model.prepareForVoiceModePresentation(startsFreshChat: true, configuration: configuration)
        #expect(model.selectedModel == option)

        await model.target.refreshCodexModels()
        #expect(model.selectedModel == option)
        #expect(model.reasoningSelection == .effort(.high))
        #expect(model.fastModeEnabled == option.supportsFastMode)

        fixture.workspace.modelPickerPreferences.setModelVisible(false, for: try #require(catalog.entry(for: CodexModelFixtures.lunaID)))
        #expect(model.selectedModel == option)
        apply(true)
        #expect(model.selectedModel == option)
        apply(false)
        #expect(model.selectedModel?.id == (provider == .codex ? CodexModelFixtures.solID : "fable"))
    }

    @Test func unavailableModelsNameTheirCause() async throws {
        let unloadedFixture = TargetModelFixture()
        defer { await unloadedFixture.cleanUp() }
        let unloadedTarget = unloadedFixture.target
        let unloaded = unloadedTarget.makeScreen(newChat: UUID())
        #expect(unloaded.target.configuredModel(id: CodexModelFixtures.solID) == .listNotLoaded)
        #expect(throws: VoiceModeConfigurationError.modelListNotLoaded) {
            try unloaded.prepareForVoiceModePresentation(startsFreshChat: true, configuration: RemoteCoderVoiceConfiguration(
                modelID: CodexModelFixtures.solID, reasoningSelectionID: nil, fastModeEnabled: false
            ))
        }

        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        for entry in try CodexModelFixtures.catalog().entries { fixture.workspace.modelPickerPreferences.setModelVisible(false, for: entry) }
        #expect(throws: VoiceModeConfigurationError.noModelShown) {
            try model.prepareForVoiceModePresentation(startsFreshChat: true, configuration: RemoteCoderVoiceConfiguration(
                modelID: nil, reasoningSelectionID: nil, fastModeEnabled: false
            ))
        }
    }

    @Test func staleClaudePreferenceCannotBlockHostModels() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        await fixture.workspace.retireEverything()
        fixture.defaults.set(["claude": "unavailable-account"], forKey: "accounts.selected-by-provider.v1")
        fixture.defaults.set(ClaudeModelCatalog.fableModelID, forKey: NewChatDefaults.modelDefaultKey)
        let defaults = fixture.defaults
        let storage = fixture.temporaryStorage.storage
        let workspace = ChatWorkspaceModel(settings: fixture.workspace.settings, defaults: defaults,
            makeModel: { ChatTargetModel(host: $0, chatDefaults: defaults, modelPickerPreferences: $1, syncedPreferences: $2, voiceCalls: TestVoiceCalls.center, backgroundExecution: StubBackgroundExecution(), uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production, storage: storage, htmlVisuals: HTMLVisualServices(directory: storage.root.appending(path: "html-visuals"))) },
            voiceCalls: TestVoiceCalls.center, makeBackgroundExecution: { StubBackgroundExecution() }, uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production, storage: storage)

        await workspace.finishHostChanges()
        for target in workspace.models { await target.restoreCachedCodexModels() }
        #expect(workspace.configuredModel(id: ClaudeModelCatalog.opusModelID).model?.id == ClaudeModelCatalog.opusModelID)
        #expect(try await CodexIntentModelCatalog.resolve(nil, in: workspace).id == ClaudeModelCatalog.fableModelID)
        #expect(workspace.configuredModel(id: CodexModelFixtures.solID).model?.id == CodexModelFixtures.solID)
        await workspace.retireEverything()
    }

    @Test func explicitlyUnsupportedEffortFailsInsteadOfSilentlyDowngrading() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let intent = RemoteCoderVoiceChatIntent()
        intent.destination = .model(CodexModelEntity(option: ClaudeModelCatalog.defaultModel))
        intent.reasoning = .ultra
        intent.fastMode = .off

        #expect(throws: VoiceModeConfigurationError.unsupportedReasoning(
            model: ClaudeModelCatalog.defaultModel.displayName, reasoning: ReasoningEffort.ultra.label
        )) {
            try model.prepareForVoiceModePresentation(startsFreshChat: true, configuration: try intent.voiceConfiguration)
        }
    }

    @Test func invalidConfigurationDoesNotClearTheCurrentChat() async {
        let message = ChatMessage(role: .user, text: "Keep this conversation")
        let fixture = TargetModelFixture()
        defer { await fixture.cleanUp() }
        let target = fixture.target
        let model = target.makeScreen(newChat: UUID())
        model.showPreview([message])
        let configuration = RemoteCoderVoiceConfiguration(
            modelID: "removed-model",
            reasoningSelectionID: "effort-xhigh",
            fastModeEnabled: false
        )

        #expect(throws: VoiceModeConfigurationError.self) {
            try model.prepareForVoiceModePresentation(startsFreshChat: true, configuration: configuration)
        }
        #expect(model.messages.map(\.id) == [message.id])
    }
}
