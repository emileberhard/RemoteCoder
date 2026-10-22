import Foundation
import Testing
@testable import RemoteCoder

@MainActor
@Suite(.serialized)
struct ChatSettingsTests {
    @Test(arguments: [false, true], [ReasoningSelection.automatic, .effort(.high)])
    func activeModelRefreshDropsRemovedDaybreakMetadataAndRestoresReappearance(
        removesModel: Bool, reasoning: ReasoningSelection
    ) async throws {
        let modelID = CodexModelFixtures.solID
        let gateway = try FakeGatewayServer(threadID: "catalog-refresh", model: modelID)
        await gateway.serveHistory([])
        await gateway.serveThreadSettings(model: modelID, effort: "high")
        let blue = CodexModelFixtures.wireModel(modelID, name: "Selected model", efforts: ["low", "medium", "high"],
            serviceTiers: ["priority"], cyberPrograms: ["daybreakBlue"])
        try await gateway.serveModels(CodexModelFixtures.models([blue]))
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let screen = try #require(fixture.workspace.selectedScreen)
        await screen.target.prepareIfNeeded()
        await screen.target.refreshCodexModels()
        var thread = try fixture.thread("catalog-refresh", updatedAt: 100)
        thread.model = modelID
        thread.reasoningEffort = .high
        screen.resumeConversation(thread)
        try #require(await waitUntil { screen.loadingTranscriptID == nil && screen.areConversationSettingsReady })
        screen.restorePicker(from: thread, saved: ConversationMetadata(sessionID: thread.id, modelID: modelID,
            reasoningSelectionID: reasoning.id, fastModeEnabled: true, source: .selection, updatedAt: .now))
        #expect(screen.selectedModel?.supportsDaybreakBlue == true)
        #expect(screen.reasoningSelection == reasoning)
        #expect(screen.fastModeState == .readback(nil, remembered: true))

        let replacement = CodexModelFixtures.wireModel(removesModel ? CodexModelFixtures.astraID : modelID,
            name: "Current discovery", efforts: ["low", "medium", "high"], cyberPrograms: ["standard"])
        try await gateway.serveModels(CodexModelFixtures.models([replacement]))
        await screen.target.refreshCodexModels()

        #expect(screen.target.codexModels.refreshError == nil)
        #expect(screen.selectedModel?.id == modelID)
        #expect(screen.selectedModel?.isListed == !removesModel)
        #expect(screen.selectedModel?.supportsDaybreakBlue == false)
        #expect(screen.reasoningSelection == reasoning)
        #expect(screen.fastModeState == .readback(nil, remembered: true))
        if removesModel {
            #expect(screen.selectedModel?.reasoningEfforts == (reasoning.effort.map { [$0] } ?? []))
        }
        try #require(await screen.prepareDraft())
        screen.input = "Continue after discovery changed"
        #expect(await fixture.workspace.send(from: screen))
        try #require(await waitUntil {
            await gateway.requests("turn/start").count == 1 && screen.currentReplyDelivery == .acknowledged
        })
        let removed = try #require(await gateway.requests("turn/start").first?.objectValue)
        #expect(removed["model"] == .string(modelID))
        #expect(removed["effort"] == reasoning.effort.map { .string($0.rawValue) })
        #expect(removed["cyberAccessProgram"] == nil)
        #expect(removed["serviceTier"] == nil)
        try await gateway.notify("turn/completed", ["threadId": .string(thread.id),
            "turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        try #require(await waitUntil { !screen.isCurrentConversationBusy })

        try await gateway.serveModels(CodexModelFixtures.models([blue]))
        await screen.target.refreshCodexModels()

        #expect(screen.selectedModel?.id == modelID)
        #expect(screen.selectedModel?.isListed == true)
        #expect(screen.selectedModel?.supportsDaybreakBlue == true)
        #expect(screen.reasoningSelection == reasoning)
        #expect(screen.fastModeState == .readback(nil, remembered: true))
        screen.input = "Continue after the model returned"
        #expect(await fixture.workspace.send(from: screen))
        try #require(await waitUntil { await gateway.requests("turn/start").count == 2 })
        let restored = try #require(await gateway.requests("turn/start").last?.objectValue)
        #expect(restored["model"] == .string(modelID))
        #expect(restored["cyberAccessProgram"] == .string("daybreakBlue"))
        #expect(restored["serviceTier"] == nil)
    }

    @Test(arguments: [nil, ConversationMetadata.Source.selection])
    func switchingFromClaudeRestoresAstraWithoutSavingTheProviderDefault(source: ConversationMetadata.Source?) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let fable = try #require(ClaudeModelCatalog.model(for: "fable"))
        model.selectModel(fable, for: nil)
        model.selectReasoning(.effort(.medium), for: nil)
        var thread = try fixture.thread("astra-thread", updatedAt: 100)
        thread.model = "gpt-6-astra"
        thread.reasoningEffort = .xhigh
        thread.extra = .init(serviceTier: "priority")
        // Simulates metadata corrupted by the previous provider-switch bug.
        let saved = ConversationMetadata(sessionID: thread.id, modelID: CodexModelFixtures.solID,
            reasoningSelectionID: "effort-high", fastModeEnabled: true, source: source, updatedAt: Date(timeIntervalSince1970: 200))
        let store = ConversationMetadataStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage)
        try await store.save(SessionMetadataLocalState(acknowledged: [thread.id: saved]))

        model.resumeConversation(thread)
        #expect(await waitUntil { model.loadingTranscriptID == nil })

        #expect(model.selectedModel?.id == "gpt-6-astra")
        #expect(model.reasoningSelection == .effort(.xhigh))
        #expect(model.fastModeSelection == nil)
        model.restorePicker(from: thread, saved: saved)
        #expect(model.fastModeEnabled)
        #expect(try await store.load().acknowledged[thread.id] == saved)
        model.startNewConversation()
        #expect(model.selectedModel?.id == "fable")
        #expect(model.reasoningSelection == .effort(.medium))
        #expect(!model.fastModeEnabled)
    }

    @Test func switchingToClaudePreservesTheLastManualFastSelection() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        model.selectModel(astra, for: nil)
        model.selectReasoning(.effort(.xhigh), for: nil)
        model.selectFastMode(true, for: nil)
        let thread = try fixture.thread("claude_existing", updatedAt: 100)
        let saved = ConversationMetadata(sessionID: thread.id, modelID: "opus",
            reasoningSelectionID: "effort-low", fastModeEnabled: false, updatedAt: .now)
        try await ConversationMetadataStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage).save(SessionMetadataLocalState(acknowledged: [thread.id: saved]))

        model.resumeConversation(thread)
        #expect(await waitUntil { model.loadingTranscriptID == nil })
        #expect(model.selectedModel?.id == "opus")
        #expect(model.reasoningSelection == .effort(.low))
        #expect(!model.fastModeEnabled)
        model.startNewConversation()
        #expect(model.selectedModel == astra)
        #expect(model.reasoningSelection == .effort(.xhigh))
        #expect(model.fastModeEnabled)
    }

    @Test func configuredIdleClaudeSelectionSurvivesReopeningBeforeItsNextTurn() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        var thread = try fixture.thread("claude_waiting", updatedAt: 100)
        thread.model = "claude-sonnet-5"
        thread.reasoningEffort = .low
        let configured = ConversationMetadata(sessionID: thread.id, modelID: "opus", reasoningSelectionID: "effort-xhigh",
            fastModeEnabled: false, source: .selection, updatedAt: Date(timeIntervalSince1970: 200))
        try await ConversationMetadataStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage).save(SessionMetadataLocalState(acknowledged: [thread.id: configured]))
        model.resumeConversation(thread)
        #expect(await waitUntil { model.loadingTranscriptID == nil })
        #expect(model.selectedModel?.id == "opus")
        #expect(model.reasoningSelection == .effort(.xhigh))
    }

    @Test(arguments: [false, true], [false, true])
    func modelAndReasoningDefaultsAreIndependent(fixedModel: Bool, fixedReasoning: Bool) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        fixture.defaults.set(fixedModel ? "gpt-6-astra" : NewChatDefaults.lastSelectedValue,
            forKey: NewChatDefaults.modelDefaultKey)
        fixture.defaults.set(fixedReasoning ? "effort-low" : NewChatDefaults.lastSelectedValue,
            forKey: NewChatDefaults.reasoningDefaultKey)
        model.selectModel(try CodexModelFixtures.option(CodexModelFixtures.lunaID), for: nil)
        model.selectReasoning(.effort(.xhigh), for: nil)
        model.startNewConversation()
        #expect(model.selectedModel?.id == (fixedModel ? "gpt-6-astra" : "gpt-5.6-luna"))
        #expect(model.reasoningSelection == (fixedReasoning ? .effort(.low) : .effort(.xhigh)))
        fixture.defaults.set(NewChatDefaults.lastSelectedValue, forKey: NewChatDefaults.modelDefaultKey)
        fixture.defaults.set(NewChatDefaults.lastSelectedValue, forKey: NewChatDefaults.reasoningDefaultKey)
        model.startNewConversation()
        #expect(model.selectedModel?.id == "gpt-5.6-luna")
        #expect(model.reasoningSelection == .effort(.xhigh))
    }

    @Test func manualEditInAnExistingChatWinsOverItsPendingRestoreAndSeedsNewChats() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        fixture.workspace.modelPickerPreferences.show(only: [.low, .medium, .high, .xhigh, .max])
        var thread = try fixture.thread("editing", updatedAt: 100)
        thread.model = "gpt-6-astra"
        thread.reasoningEffort = .low
        model.resumeConversation(thread)
        model.selectModel(try CodexModelFixtures.option(CodexModelFixtures.lunaID), for: thread.id)
        model.selectReasoning(.effort(.max), for: thread.id)
        #expect(await waitUntil { model.loadingTranscriptID == nil && !model.isUpdatingSettings(for: thread.id) })
        #expect(model.selectedModel?.id == "gpt-5.6-luna")
        #expect(model.reasoningSelection == .effort(.max))
        model.startNewConversation()
        #expect(model.selectedModel?.id == "gpt-5.6-luna")
        #expect(model.reasoningSelection == .effort(.max))
    }

    @Test func unknownConversationSettingsDoNotInheritThePreviousChat() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let thread = try fixture.thread("claude_unknown", updatedAt: 100)
        model.resumeConversation(thread)
        #expect(await waitUntil { model.loadingTranscriptID == nil })
        #expect(!model.areConversationSettingsReady)
        #expect(!model.isLoadingConversationSettings)
        #expect(model.settingsUpdateError(for: thread.id) != nil)
        #expect(await model.prepareDraft())
        model.input = "Do not send with a guessed model"
        #expect(await model.send() == false)
    }

    @Test func hiddenDefaultEffortIsClampedWithoutDiscardingTheSavedPreference() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        fixture.defaults.set("fable", forKey: NewChatDefaults.modelDefaultKey)
        fixture.defaults.set("effort-ultra", forKey: NewChatDefaults.reasoningDefaultKey)
        model.startNewConversation()
        #expect(model.reasoningSelection == .effort(.xhigh))
        fixture.defaults.set("gpt-6-astra", forKey: NewChatDefaults.modelDefaultKey)
        model.startNewConversation()
        #expect(model.reasoningSelection == .effort(.xhigh))
        fixture.workspace.modelPickerPreferences.show(only: [.low, .medium, .high, .xhigh, .max, .ultra])
        model.startNewConversation()
        #expect(model.reasoningSelection == .effort(.ultra))
    }

    @Test func hidingBothEndsClampsTheCurrentSelectionAndRememberedModelChoice() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        model.selectReasoning(.effort(.low), for: nil)
        fixture.workspace.modelPickerPreferences.show(only: [.medium, .high])
        #expect(model.reasoningSelection == .effort(.medium))
        model.selectReasoning(.effort(.max), for: nil)
        #expect(model.reasoningSelection == .effort(.medium))
        model.selectModel(try #require(ClaudeModelCatalog.model(for: "fable")), for: nil)
        model.selectReasoning(.effort(.xhigh), for: nil)
        model.selectModel(try CodexModelFixtures.option(CodexModelFixtures.solID), for: nil)
        #expect(model.reasoningSelection == .effort(.medium))
    }

    @Test(arguments: ["fast", "priority"])
    func liveSettingsUpdateIsConversationScopedAndNeverChangesNewChatDefaults(tier: String) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        model.selectModel(astra, for: nil)
        model.selectReasoning(.effort(.xhigh), for: nil)
        model.setActiveSessionID("selected")
        let event = try #require(GatewayNotificationRouting.route(GatewayEventFixture.notification(
            method: "thread/settings/updated", params: .object([
                "threadId": .string("selected"), "threadSettings": .object([
                    "model": .string("gpt-5.6-luna"), "effort": .string("low"), "serviceTier": .string(tier),
                ]),
            ]), receivedAt: .now, sequence: nil
        )))
        let revisionBeforeChange = model.settingsSelectionRevision
        await model.target.apply(gatewayEvent: event)
        #expect(model.settingsSelectionRevision != revisionBeforeChange)
        #expect(model.selectedModel?.id == "gpt-5.6-luna")
        #expect(model.reasoningSelection == .effort(.low))
        #expect(model.fastModeEnabled)
        let revisionAfterChange = model.settingsSelectionRevision
        await model.target.apply(gatewayEvent: event)
        #expect(model.settingsSelectionRevision == revisionAfterChange)
        model.startNewConversation()
        #expect(model.selectedModel == astra)
        #expect(model.reasoningSelection == .effort(.xhigh))
        #expect(!model.fastModeEnabled)
        await model.target.apply(gatewayEvent: event, replay: true)
        #expect(model.selectedModel == astra)
    }

    @Test func liveSettingsPayloadDoesNotScheduleAWholeMetadataRead() async throws {
        let gateway = try FakeGatewayServer(threadID: "selected")
        let port = try await gateway.start()
        let fixture = await WorkspaceFixture(miniGatewayPort: port)
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp(); await gateway.stop() }
        let screen = try #require(fixture.workspace.selectedScreen)
        await screen.target.metadataService.sync()
        #expect(await screen.target.metadataService.status.error == nil)
        let reads = await gateway.requests("conversation/metadata/read").count
        #expect(reads == 1)
        screen.setActiveSessionID("selected")
        let event = try settingsEvent(threadID: "selected", model: CodexModelFixtures.astraID,
            effort: "high", tier: "priority")
        await screen.target.apply(gatewayEvent: event)
        #expect(screen.selectedModel?.id == CodexModelFixtures.astraID)
        #expect(screen.reasoningSelection == .effort(.high))
        #expect(screen.fastModeEnabled)
        let reread = await waitUntil(timeout: .seconds(1)) {
            await gateway.requests("conversation/metadata/read").count > reads
        }
        #expect(!reread)
    }

    @Test(arguments: [false, true])
    func externalSettingsChangeCannotRestoreStalePreferencesOnReopen(claude: Bool) async throws {
        let threadID = claude ? "claude_11111111-1111-1111-1111-111111111111" : "thread"
        let modelID = claude ? "opus" : CodexModelFixtures.astraID
        let gateway = try FakeGatewayServer(threadID: threadID, model: modelID)
        await gateway.serveHistory([])
        await gateway.serveThreadSettings(model: modelID, effort: claude ? nil : "high")
        var saved = ConversationMetadata(sessionID: threadID, modelID: modelID,
            reasoningSelectionID: claude ? "effort-low" : "automatic", fastModeEnabled: false,
            source: .selection, updatedAt: Date(timeIntervalSince1970: 200), serverRevision: 1)
        let acknowledged = saved
        try await gateway.serveMetadata([saved])
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp(); await gateway.stop() }
        let screen = try #require(fixture.workspace.selectedScreen)
        var header = try ThreadFixture.basic(threadID, updatedAt: 100, fields: ["status": ["type": "notLoaded"]])
        header.model = modelID
        header.reasoningEffort = claude ? nil : .high
        await screen.target.metadataService.sync()
        #expect(await screen.target.metadataService.status.error == nil)
        screen.setActiveSessionID(threadID)
        screen.restorePicker(from: header, saved: saved)
        #expect(screen.reasoningSelection == (claude ? .effort(.low) : .automatic))
        saved.reasoningSelectionID = "effort-high"
        saved.serverRevision = 2
        saved.updatedAt = Date(timeIntervalSince1970: 300)
        try await gateway.serveMetadata([saved])
        let reads = await gateway.requests("conversation/metadata/read").count
        await screen.target.apply(gatewayEvent: try settingsEvent(threadID: threadID,
            model: modelID, effort: "high", tier: nil))
        #expect(screen.reasoningSelection == .effort(.high))
        #expect(await gateway.requests("conversation/metadata/read").count == reads)
        screen.startNewConversation()
        screen.resumeConversation(header)
        #expect(await waitUntil { screen.loadingTranscriptID == nil && !screen.isLoadingConversationSettings })
        #expect(screen.reasoningSelection == .effort(.high))
        #expect(await gateway.requests("conversation/metadata/read").count == reads)
        #expect(await gateway.requests("conversation/metadata/update").isEmpty)
        let store = ConversationMetadataStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage)
        let persisted = try await store.load()
        #expect(persisted.acknowledged[threadID] == acknowledged)
        let observation = try #require(persisted.observed?[threadID])
        #expect(observation.metadata.reasoningSelectionID == "effort-high")
        #expect(observation.acknowledgedRevision == acknowledged.serverRevision)
        await screen.target.metadataService.sync()
        #expect(await gateway.requests("conversation/metadata/read").count == reads + 1)
        let synchronized = try await store.load()
        #expect(synchronized.acknowledged[threadID] == saved)
        #expect(synchronized.observed?[threadID] == nil)
        #expect(await gateway.requests("conversation/metadata/update").isEmpty)
    }

    @Test(arguments: ["opus", NewChatDefaults.lastSelectedValue])
    func fastPreferenceSurvivesUnsupportedModelsAndProviderDefaults(defaultModel: String) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        model.selectModel(astra, for: nil)
        model.selectFastMode(true, for: nil)
        fixture.defaults.set(defaultModel, forKey: NewChatDefaults.modelDefaultKey)
        model.startNewConversation()
        model.selectDefaultModel(for: .codex)
        #expect(model.fastModeEnabled)
        model.selectModel(spark, for: nil)
        #expect(!model.fastModeEnabled)
        #expect(model.serviceTierOverride == .clear)
        model.selectModel(astra, for: nil)
        #expect(model.fastModeEnabled)
        model.selectFastMode(false, for: nil)
        model.selectModel(spark, for: nil)
        model.selectModel(astra, for: nil)
        #expect(!model.fastModeEnabled)
        #expect(model.fastModeSelection == false)
    }

    @Test(arguments: ["priority", "default", "flex", "future"])
    func authoritativeReadbackWinsOverSavedFastMetadata(tier: String) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        var thread = try fixture.thread("tier-readback", updatedAt: 100)
        thread.model = CodexModelFixtures.astraID
        thread.extra = .init(serviceTier: tier)
        let saved = ConversationMetadata(sessionID: thread.id, modelID: CodexModelFixtures.astraID,
            reasoningSelectionID: "effort-high", fastModeEnabled: tier != "priority", source: .selection, updatedAt: .now)
        try await ConversationMetadataStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage).save(.init(acknowledged: [thread.id: saved]))
        model.resumeConversation(thread)
        #expect(await waitUntil { model.loadingTranscriptID == nil })
        #expect(model.fastModeSelection == nil)
        model.restorePicker(from: thread, saved: saved)
        let expected: Bool? = tier == "default" ? false : tier == "priority" ? true : nil
        #expect(model.fastModeSelection == expected)
        #expect(model.serviceTierOverride == expected.map { $0 ? .set(.fast) : .clear })
    }

    @Test func missingTierReadbackPreservesTheServerSettingUntilAnExplicitChoice() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        var thread = try fixture.thread("unloaded-tier", updatedAt: 100)
        thread.model = CodexModelFixtures.astraID
        model.resumeConversation(thread)
        #expect(await waitUntil { model.loadingTranscriptID == nil })
        #expect(model.fastModeSelection == nil)
        #expect(model.serviceTierOverride == nil)
        model.selectReasoning(.effort(.medium), for: thread.id)
        #expect(model.fastModeSelection == nil)
        #expect(model.serviceTierOverride == nil)
        model.selectFastMode(false, for: thread.id)
        #expect(model.fastModeSelection == false)
        #expect(model.serviceTierOverride == .clear)
    }

    @Test(arguments: [CodexModelFixtures.sparkID, CodexModelFixtures.astraID])
    func offReadbackKeepsTheSavedFastChoiceUntilAFastCapableModelIsSelected(threadModelID: String) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        var thread = try fixture.thread("off-readback", updatedAt: 100)
        thread.model = threadModelID
        thread.extra = .init(serviceTier: nil)
        let saved = ConversationMetadata(sessionID: thread.id, modelID: threadModelID,
            reasoningSelectionID: "effort-high", fastModeEnabled: true, source: .selection, updatedAt: .now)
        model.setActiveSessionID(thread.id)
        model.restorePicker(from: thread, saved: saved)
        #expect(model.fastModeSelection == false)
        #expect(!model.fastModeEnabled)
        #expect(model.serviceTierOverride == .clear)
        model.selectReasoning(.effort(.medium), for: thread.id)
        #expect(model.fastModeSelection == false)
        #expect(model.serviceTierOverride == .clear)
        model.selectModel(spark, for: thread.id)
        #expect(model.fastModeSelection == false)
        model.selectModel(astra, for: thread.id)
        #expect(model.fastModeSelection == true)
        #expect(model.serviceTierOverride == .set(.fast))
    }

    @Test func pendingReasoningEditRetainsRememberedFastChoiceAcrossConversationSwitch() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        var thread = try fixture.thread("pending-remembered-fast", updatedAt: 100)
        thread.model = spark.id
        thread.extra = .init(serviceTier: nil)
        let saved = ConversationMetadata(sessionID: thread.id, modelID: spark.id,
            reasoningSelectionID: "automatic", fastModeEnabled: true, source: .selection, updatedAt: .now)
        model.setActiveSessionID(thread.id)
        model.restorePicker(from: thread, saved: saved)
        model.selectReasoning(.effort(.medium), for: thread.id)
        #expect(model.isUpdatingSettings(for: thread.id))
        model.startNewConversation()
        model.resumeConversation(thread)
        #expect(model.fastModeSelection == nil)
        #expect(model.fastModeState.remembered == true)
        #expect(model.restorePendingConversationSettings(for: thread.id))
        #expect(model.fastModeSelection == false)
        #expect(model.fastModeState.remembered == true)
        model.selectModel(astra, for: thread.id)
        #expect(model.fastModeSelection == true)
        #expect(model.serviceTierOverride == .set(.fast))
    }

    @Test func cachedRestoreKeepsRememberedFastChoiceThroughReasoningEdit() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        var thread = try fixture.thread("cached-remembered-fast", updatedAt: 100)
        thread.model = spark.id
        thread.extra = .init(serviceTier: nil)
        let saved = ConversationMetadata(sessionID: thread.id, modelID: spark.id,
            reasoningSelectionID: "automatic", fastModeEnabled: true, source: .selection, updatedAt: .now)
        model.setActiveSessionID(thread.id)
        model.restorePicker(from: thread, saved: saved)
        model.startNewConversation()
        model.resumeConversation(thread)
        #expect(model.selectedModel == spark)
        #expect(model.fastModeSelection == nil)
        #expect(model.fastModeState.remembered == true)
        model.selectReasoning(.effort(.medium), for: thread.id)
        #expect(model.fastModeSelection == nil)
        #expect(model.fastModeState.remembered == true)
        model.selectModel(astra, for: thread.id)
        #expect(model.fastModeSelection == true)
        #expect(model.serviceTierOverride == .set(.fast))
    }

    @Test func incomingOffscreenCallRestoresItsOwnSavedFastChoiceBeforeTierReadback() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        let threadID = "incoming-saved-fast"
        let saved = ConversationMetadata(sessionID: threadID, modelID: spark.id,
            reasoningSelectionID: "automatic", fastModeEnabled: true, source: .selection, updatedAt: .now)
        try await ConversationMetadataStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage)
            .save(SessionMetadataLocalState(acknowledged: [threadID: saved]))
        let model = try #require(fixture.workspace.selectedScreen)
        model.selectModel(astra, for: nil)
        model.selectFastMode(false, for: nil)
        model.setActiveSessionID("different-visible-thread")
        let callID = UUID()
        let push = AgentCallPush(callId: callID, hostId: fixture.mini.id,
            expiresAt: Date.now.addingTimeInterval(60).timeIntervalSince1970)
        let status = AgentCallStatus(callId: callID, conversationThreadId: threadID,
            provider: "codex", state: .ringing, expiresAt: push.expiresAt,
            cwd: "/repo", model: spark.id, effort: "medium")
        let context = try status.voiceContext(for: push, at: .now)
        #expect(context.fastModeSelection == nil)
        let remembered = await model.incomingVoiceFastModeState(for: context)
        #expect(remembered == .readback(nil, remembered: true))
        #expect(model.fastModeSelection == false)
        var differentModel = context
        differentModel.model = astra.id
        #expect(await model.incomingVoiceFastModeState(for: differentModel).remembered == true)
        var explicitChoice = context
        explicitChoice.fastModeState = .selection(false)
        #expect(await model.incomingVoiceFastModeState(for: explicitChoice).remembered == false)
    }

    @Test func incomingReadCannotPublishOldOffAfterFastEditAndNavigation() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        var thread = try fixture.thread("incoming-race", updatedAt: 100)
        thread.model = astra.id
        thread.extra = .init(serviceTier: nil)
        let saved = ConversationMetadata(sessionID: thread.id, modelID: astra.id,
            reasoningSelectionID: "automatic", fastModeEnabled: true, source: .selection, updatedAt: .now)
        try await ConversationMetadataStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage)
            .save(.init(acknowledged: [thread.id: saved]))
        model.setActiveSessionID(thread.id)
        model.restorePicker(from: thread, saved: saved)
        let callID = UUID()
        let push = AgentCallPush(callId: callID, hostId: fixture.mini.id,
            expiresAt: Date.now.addingTimeInterval(60).timeIntervalSince1970)
        let status = AgentCallStatus(callId: callID, conversationThreadId: thread.id,
            provider: "codex", state: .ringing, expiresAt: push.expiresAt,
            cwd: "/repo", model: astra.id, effort: "medium")
        let context = try status.voiceContext(for: push, at: .now)
        let suspended = SuspendedIncomingThreadRead()
        let read = Task {
            await model.readIncomingVoiceSettings(context, using: model.target.gatewayClient,
                ownsCall: { true }, readThread: { _ in try await suspended.read() }).context
        }
        await suspended.waitUntilStarted()
        model.selectFastMode(true, for: thread.id)
        model.setActiveSessionID("other-thread")
        #expect(await waitUntil { !model.isUpdatingSettings(for: thread.id) })
        await suspended.complete(with: .init(thread))
        let result = await read.value
        #expect(result.fastModeSelection == nil)
        #expect(result.fastModeState.remembered == true)
    }

    @Test func incomingFullReadReplacesRingingAcknowledgementAfterNavigation() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let controller = model.target.realtimeVoice
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        var thread = try fixture.thread("ringing-settings", updatedAt: 100)
        thread.model = astra.id
        thread.reasoningEffort = .high
        thread.extra = .init(serviceTier: nil)
        let callID = UUID()
        defer { controller.clearIncomingSettingsOwner(callID: callID) }
        let push = AgentCallPush(callId: callID, hostId: fixture.mini.id,
            expiresAt: Date.now.addingTimeInterval(60).timeIntervalSince1970)
        let status = AgentCallStatus(callId: callID, conversationThreadId: thread.id,
            provider: "codex", state: .ringing, expiresAt: push.expiresAt,
            cwd: "/repo", model: astra.id, effort: "medium")
        model.setActiveSessionID(thread.id)
        controller.bindIncomingSettingsOwner(push: push, model: model.target, deviceID: "test")
        controller.applyConversationSettings(ConversationSettingsUpdate(threadID: thread.id,
            model: astra, reasoning: .effort(.medium), fastModeState: .selection(true)),
            hostID: model.hostID)
        model.setActiveSessionID("other-thread")
        await model.target.apply(gatewayEvent: try settingsEvent(threadID: thread.id, model: astra.id,
            effort: "high", tier: nil))
        let context = try status.voiceContext(for: push, at: .now)
        let readResponse = CodexAppServerV2.ThreadReadResponse(thread)
        let prepared = await controller.prepareIncomingConversationContext(context, using: model.target,
            gateway: model.target.gatewayClient, readThread: { _ in readResponse })
        let firstPublication = controller.publishConversationContext(prepared)
        #expect(firstPublication.model == astra.id)
        #expect(firstPublication.effort == "high")
        #expect(firstPublication.fastModeSelection == false)
        let answerRevision = try #require(controller.incomingSettingsRevision(for: firstPublication,
            hostID: model.hostID))
        let published = controller.publishIncomingAnswerContext(firstPublication,
            model: CodexModelFixtures.solID, effort: "xhigh", settingsGeneration: answerRevision)
        #expect(published.fastModeSelection == false)
        #expect(published.model == CodexModelFixtures.solID)
        #expect(controller.conversationContext?.effort == "xhigh")
    }

    @Test func offscreenIncomingObservationDuringReadKeepsRememberedFastChoice() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        var thread = try fixture.thread("offscreen-incoming", updatedAt: 100)
        thread.model = spark.id
        thread.extra = .init(serviceTier: nil)
        try await ConversationMetadataStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage).save(.init(acknowledged: [
            thread.id: ConversationMetadata(sessionID: thread.id, modelID: spark.id,
                reasoningSelectionID: "automatic", fastModeEnabled: true, source: .selection, updatedAt: .now)
        ]))
        let model = try #require(fixture.workspace.selectedScreen)
        let controller = model.target.realtimeVoice
        let callID = UUID()
        defer { controller.clearIncomingSettingsOwner(callID: callID) }
        let push = AgentCallPush(callId: callID, hostId: fixture.mini.id,
            expiresAt: Date.now.addingTimeInterval(60).timeIntervalSince1970)
        let status = AgentCallStatus(callId: callID, conversationThreadId: thread.id,
            provider: "codex", state: .ringing, expiresAt: push.expiresAt,
            cwd: "/repo", model: spark.id, effort: "medium")
        model.setActiveSessionID("other-thread")
        controller.bindIncomingSettingsOwner(push: push, model: model.target, deviceID: "test")
        let context = try status.voiceContext(for: push, at: .now)
        let suspended = SuspendedIncomingThreadRead()
        let preparation = Task {
            await controller.prepareIncomingConversationContext(context, using: model.target,
                gateway: model.target.gatewayClient, readThread: { _ in try await suspended.read() })
        }
        await suspended.waitUntilStarted()
        await model.target.apply(gatewayEvent: try settingsEvent(threadID: thread.id, model: spark.id,
            effort: "high", tier: nil))
        await suspended.complete(with: .init(thread))
        let prepared = await preparation.value
        let published = controller.publishConversationContext(prepared)
        #expect(published.fastModeSelection == false)
        #expect(published.effort == "high")
        #expect(published.fastModeState.remembered == true)
        #expect(controller.conversationContext?.fastModeState.remembered == true)
    }

    @Test(arguments: [
        ("{}", true), ("{\"serviceTier\":\"flex\"}", nil), ("{\"serviceTier\":\"default\"}", false),
    ] as [(String, Bool?)])
    func incomingReadOnlySupersedesRingingChoiceWhenTierWasReported(extraJSON: String, fastMode: Bool?) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let controller = model.target.realtimeVoice
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        let sol = try CodexModelFixtures.option(CodexModelFixtures.solID)
        var thread = try fixture.thread("incoming-tier-coverage", updatedAt: 100)
        thread.model = sol.id
        thread.reasoningEffort = .high
        thread.extra = try JSONDecoder().decode(CodexAppServerV2.ThreadExtra.self, from: Data(extraJSON.utf8))
        let callID = UUID()
        defer { controller.clearIncomingSettingsOwner(callID: callID) }
        let push = AgentCallPush(callId: callID, hostId: fixture.mini.id,
            expiresAt: Date.now.addingTimeInterval(60).timeIntervalSince1970)
        let status = AgentCallStatus(callId: callID, conversationThreadId: thread.id,
            provider: "codex", state: .ringing, expiresAt: push.expiresAt,
            cwd: "/repo", model: astra.id, effort: "medium")
        model.setActiveSessionID(thread.id)
        controller.bindIncomingSettingsOwner(push: push, model: model.target, deviceID: "test")
        controller.applyConversationSettings(ConversationSettingsUpdate(threadID: thread.id,
            model: astra, reasoning: .effort(.medium), fastModeState: .selection(true)),
            hostID: model.hostID)
        let context = try status.voiceContext(for: push, at: .now)
        let readResponse = CodexAppServerV2.ThreadReadResponse(thread)
        let prepared = await controller.prepareIncomingConversationContext(context, using: model.target,
            gateway: model.target.gatewayClient, readThread: { _ in readResponse })
        let published = controller.publishConversationContext(prepared)
        #expect(published.model == sol.id)
        #expect(published.effort == "high")
        #expect(published.fastModeSelection == fastMode)
        let answerRevision = try #require(controller.incomingSettingsRevision(for: published,
            hostID: model.hostID))
        let answered = controller.publishIncomingAnswerContext(published,
            model: sol.id, effort: "xhigh", settingsGeneration: answerRevision)
        #expect(answered.model == sol.id)
        #expect(answered.effort == "xhigh")
        #expect(answered.fastModeSelection == fastMode)
    }

    @Test(arguments: [false, true])
    func claudeIncomingReadAndAnswerReplaceOnlyOlderEditsWithoutATier(newerEditDuringAnswer: Bool) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let controller = model.target.realtimeVoice
        let fable = try #require(ClaudeModelCatalog.model(for: ClaudeModelCatalog.fableModelID))
        let opus = try #require(ClaudeModelCatalog.model(for: ClaudeModelCatalog.opusModelID))
        var thread = try fixture.thread("claude_incoming-settings", updatedAt: 100)
        thread.model = opus.id
        thread.reasoningEffort = .high
        let callID = UUID()
        defer { controller.clearIncomingSettingsOwner(callID: callID) }
        let push = AgentCallPush(callId: callID, hostId: fixture.mini.id,
            expiresAt: Date.now.addingTimeInterval(60).timeIntervalSince1970)
        let status = AgentCallStatus(callId: callID, conversationThreadId: thread.id,
            provider: "claude", state: .ringing, expiresAt: push.expiresAt,
            cwd: "/repo", model: fable.id, effort: "medium")
        model.setActiveSessionID(thread.id)
        controller.bindIncomingSettingsOwner(push: push, model: model.target, deviceID: "test")
        controller.applyConversationSettings(ConversationSettingsUpdate(threadID: thread.id,
            model: fable, reasoning: .effort(.xhigh), fastModeState: .readback(nil, remembered: nil)),
            hostID: model.hostID)
        model.setActiveSessionID("other-thread")
        let context = try status.voiceContext(for: push, at: .now)
        let readResponse = CodexAppServerV2.ThreadReadResponse(thread)
        let prepared = await controller.prepareIncomingConversationContext(context, using: model.target,
            gateway: model.target.gatewayClient, readThread: { _ in readResponse })
        let published = controller.publishConversationContext(prepared)
        #expect(published.model == opus.id)
        #expect(published.effort == "high")
        #expect(published.fastModeSelection == nil)
        let answerRevision = try #require(controller.incomingSettingsRevision(for: published,
            hostID: model.hostID))
        if newerEditDuringAnswer {
            controller.applyConversationSettings(ConversationSettingsUpdate(threadID: thread.id,
                model: fable, reasoning: .effort(.max), fastModeState: .readback(nil, remembered: nil)),
                hostID: model.hostID)
        }
        let answered = controller.publishIncomingAnswerContext(published,
            model: opus.id, effort: "low", settingsGeneration: answerRevision)
        #expect(answered.model == (newerEditDuringAnswer ? fable.id : opus.id))
        #expect(answered.effort == (newerEditDuringAnswer ? "max" : "low"))
        #expect(answered.fastModeSelection == nil)
    }

    @Test func unrelatedSettingsEventDoesNotStrandConversationRestore() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        var thread = try fixture.thread("restoring-a", updatedAt: 100)
        thread.model = CodexModelFixtures.astraID
        thread.extra = .init(serviceTier: nil)
        model.resumeConversation(thread)
        #expect(model.isLoadingConversationSettings)
        await model.target.apply(gatewayEvent: try settingsEvent(threadID: "unrelated-b",
            model: CodexModelFixtures.solID, effort: "high", tier: "fast"))
        #expect(await waitUntil { model.areConversationSettingsReady })
        #expect(model.selectedModel?.id == thread.model)
    }

    @Test(arguments: [false, true])
    func cacheMissObservationCannotInheritPreviousThreadsRememberedFastChoice(savedFast: Bool) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        model.selectModel(astra, for: nil)
        model.selectFastMode(!savedFast, for: nil)
        model.setActiveSessionID("previous-b")
        #expect(model.fastModeState.remembered == !savedFast)
        var thread = try fixture.thread("uncached-a", updatedAt: 100)
        thread.model = astra.id
        try await ConversationMetadataStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage).save(.init(acknowledged: [
            thread.id: ConversationMetadata(sessionID: thread.id, modelID: astra.id,
                reasoningSelectionID: "automatic", fastModeEnabled: savedFast, source: .selection, updatedAt: .now)
        ]))
        model.resumeConversation(thread)
        #expect(model.isLoadingConversationSettings)
        #expect(model.fastModeSelection == nil)
        #expect(model.fastModeState.remembered == nil)
        try #require(await waitUntil { model.loadingTranscriptID == nil && model.areConversationSettingsReady })
        #expect(model.fastModeSelection == nil)
        #expect(model.fastModeState.remembered == savedFast)
        await model.target.apply(gatewayEvent: try settingsEvent(threadID: thread.id,
            model: astra.id, effort: "medium", tier: nil))
        #expect(model.areConversationSettingsReady)
        #expect(model.fastModeSelection == false)
        #expect(model.fastModeState.remembered == savedFast)
        model.selectReasoning(.effort(.high), for: thread.id)
        #expect(model.fastModeState.remembered == savedFast)
        #expect(try await ConversationMetadataStore(hostID: fixture.mini.id, storage: fixture.temporaryStorage.storage)
            .load().acknowledged[thread.id]?.fastModeEnabled == savedFast)
    }

    private func settingsEvent(threadID: String, model: String, effort: String,
                               tier: String?) throws -> RoutedGatewayEvent {
        try #require(GatewayNotificationRouting.route(GatewayEventFixture.notification(
            method: "thread/settings/updated", params: .object([
                "threadId": .string(threadID), "threadSettings": .object([
                    "model": .string(model), "effort": .string(effort),
                    "serviceTier": tier.map(JSONValue.string) ?? .null,
                ]),
            ]), receivedAt: .now, sequence: nil
        )))
    }

    @Test func knownFastReadbackClearsOnAnUnsupportedModelAndRestoresOnSwitchBack() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        var thread = try fixture.thread("known-fast-tier", updatedAt: 100)
        thread.model = astra.id
        thread.extra = .init(serviceTier: "priority")
        model.setActiveSessionID(thread.id)
        model.restorePicker(from: thread, saved: nil)
        #expect(model.fastModeSelection == true)
        #expect(model.serviceTierOverride == .set(.fast))
        model.selectModel(spark, for: thread.id)
        #expect(model.fastModeSelection == true)
        #expect(model.serviceTierOverride == .clear)
        #expect(model.fastModeState.remembered == true)
        var reopened = thread
        reopened.model = spark.id
        reopened.extra = .init(serviceTier: nil)
        model.restorePicker(from: reopened, saved: ConversationMetadata(
            sessionID: thread.id, modelID: spark.id, reasoningSelectionID: "automatic",
            fastModeEnabled: true, source: .selection, updatedAt: .now))
        #expect(model.fastModeState.remembered == true)
        model.selectModel(astra, for: thread.id)
        #expect(model.fastModeSelection == true)
        #expect(model.serviceTierOverride == .set(.fast))
    }

    @Test(arguments: [false, true], [nil, "flex", "future"] as [String?])
    func unknownTierOnAnUnsupportedModelIsOmittedUntilAFastCapableSelection(savedFast: Bool, reportedTier: String?) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        var thread = try fixture.thread("unknown-tier", updatedAt: 100)
        thread.model = spark.id
        thread.extra = reportedTier.map { .init(serviceTier: $0) }
        let saved = ConversationMetadata(sessionID: thread.id, modelID: spark.id,
            reasoningSelectionID: "effort-high", fastModeEnabled: savedFast,
            source: .selection, updatedAt: .now)
        model.setActiveSessionID(thread.id)
        model.restorePicker(from: thread, saved: saved)
        #expect(model.fastModeSelection == nil)
        #expect(model.serviceTierOverride == nil)
        model.selectReasoning(.effort(.medium), for: thread.id)
        #expect(model.fastModeSelection == nil)
        #expect(model.fastModeState.remembered == savedFast)
        #expect(model.serviceTierOverride == nil)
        model.selectModel(astra, for: thread.id)
        #expect(model.fastModeSelection == savedFast)
        #expect(model.serviceTierOverride == (savedFast ? .set(.fast) : .clear))
    }

    @Test func restoredFastCaptureKeepsUnknownReadbackAndRememberedPreference() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        model.selectModel(astra, for: nil)
        model.selectFastMode(true, for: nil)
        model.selectReasoning(.effort(.medium), for: nil)
        model.setActiveSessionID("restored-tier")
        let revision = model.settingsSelectionRevision

        await model.target.apply(gatewayEvent: try settingsEvent(threadID: "restored-tier",
            model: astra.id, effort: "medium", tier: "fast"))
        let selectedRevision = model.settingsSelectionRevision
        #expect(selectedRevision == revision)
        #expect(model.fastModeState == .readback(true, remembered: true))
        await model.target.apply(gatewayEvent: try settingsEvent(threadID: "restored-tier",
            model: astra.id, effort: "medium", tier: "fast"))
        #expect(model.settingsSelectionRevision == selectedRevision)

        await model.target.apply(gatewayEvent: try settingsEvent(threadID: "restored-tier",
            model: astra.id, effort: "medium", tier: "flex"))
        let unknown = model.fastModeState
        #expect(unknown == .readback(nil, remembered: true))
        #expect(model.settingsSelectionRevision != selectedRevision)

        let unknownRevision = model.settingsSelectionRevision
        await model.target.apply(gatewayEvent: try settingsEvent(threadID: "restored-tier",
            model: astra.id, effort: "medium", tier: "future"))
        #expect(model.settingsSelectionRevision == unknownRevision)
        #expect(model.fastModeState.hasSameChoice(as: unknown))
        #expect(!model.fastModeState.hasSameChoice(as: .selection(false)))
    }

    @Test(arguments: [false, true], ["flex", "future"])
    func liveUnrepresentableTierDoesNotInheritAnUnsupportedModelsPreviousFastChoice(
        previousFast: Bool, tier: String
    ) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        model.selectModel(astra, for: nil)
        model.selectFastMode(previousFast, for: nil)
        model.setActiveSessionID("live-tier")
        let event = try #require(GatewayNotificationRouting.route(GatewayEventFixture.notification(
            method: "thread/settings/updated", params: .object([
                "threadId": .string("live-tier"), "threadSettings": .object([
                    "model": .string(CodexModelFixtures.sparkID), "effort": .string("medium"),
                    "serviceTier": .string(tier),
                ]),
            ]), receivedAt: .now, sequence: nil
        )))
        await model.target.apply(gatewayEvent: event)
        #expect(model.fastModeSelection == nil)
        #expect(model.serviceTierOverride == nil)
        model.selectReasoning(.effort(.high), for: "live-tier")
        #expect(model.fastModeSelection == nil)
        #expect(model.serviceTierOverride == nil)
    }

    @Test func newerFastChoiceSurvivesLateDispatchReadback() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        var thread = try fixture.thread("resume-tier", updatedAt: 100)
        thread.model = astra.id
        thread.extra = .init(serviceTier: "flex")
        model.restorePicker(from: thread, saved: nil)
        #expect(model.fastModeSelection == nil)
        let dispatchRevision = model.settingsSelectionRevision
        model.selectFastMode(true, for: nil)
        model.setActiveSessionID(thread.id)
        #expect(!model.acceptThreadTierReadback(.init(serviceTier: nil), threadID: thread.id,
            selectionRevision: dispatchRevision))
        #expect(model.fastModeSelection == true)
        #expect(model.serviceTierOverride == .set(.fast))
    }

    @Test(arguments: [("priority", false, true), ("default", true, false), ("flex", true, nil), ("future", true, nil)]
        as [(String, Bool, Bool?)])
    func currentResumeReadbackReplacesTheCapturedFastChoiceBeforeAnotherSettingsEdit(
        tier: String, capturedFast: Bool, expected: Bool?
    ) async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        model.selectModel(astra, for: nil)
        model.selectFastMode(capturedFast, for: nil)
        model.setActiveSessionID("resume-tier")
        let revision = model.settingsSelectionRevision
        #expect(model.acceptThreadTierReadback(.init(serviceTier: tier), threadID: "resume-tier",
            selectionRevision: revision))
        #expect(model.fastModeSelection == expected)
        model.selectReasoning(.effort(.medium), for: "resume-tier")
        #expect(model.fastModeSelection == expected)
        #expect(model.serviceTierOverride == expected.map { $0 ? .set(.fast) : .clear })
    }

    @Test func drawerForkOmitsTheVisibleConversationsTierForAnotherThread() async throws {
        let fixture = await WorkspaceFixture()
        await fixture.restoreCachedModels()
        defer { fixture.workspace.teardown(); await fixture.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        model.selectModel(try CodexModelFixtures.option(CodexModelFixtures.astraID), for: nil)
        model.selectFastMode(false, for: nil)
        model.setActiveSessionID("visible")
        #expect(model.forkServiceTier(for: "visible") == .clear)
        #expect(model.forkServiceTier(for: "drawer-thread") == nil)
    }

    private func freshVoiceGateway(effort: String?, tier: String?) async throws -> FakeGatewayServer {
        let gateway = try FakeGatewayServer(threadID: "voice-thread", model: CodexModelFixtures.solID)
        await gateway.serveHistory([])
        await gateway.serveThreadSettings(model: CodexModelFixtures.solID, effort: effort)
        await gateway.serveThreadTier(tier)
        try await gateway.serveModels(CodexModelFixtures.models())
        return gateway
    }

    private func freshVoiceScreen(_ fixture: WorkspaceFixture, fastMode: Bool) async throws -> ChatScreenModel {
        let screen = try #require(fixture.workspace.selectedScreen)
        await screen.target.prepareIfNeeded()
        await screen.target.refreshCodexModels()
        screen.selectModel(try CodexModelFixtures.option(CodexModelFixtures.solID), for: nil)
        screen.selectReasoning(.effort(.medium), for: nil)
        screen.selectFastMode(fastMode, for: nil)
        screen.selectWorkingDirectory("/repo")
        return screen
    }

    @Test(arguments: [(true, "priority"), (false, nil)] as [(Bool, String?)])
    func voiceThreadStartedWithTheSelectedSettingsNeedsNoSettingsUpdate(fastMode: Bool, tier: String?) async throws {
        let gateway = try await freshVoiceGateway(effort: "medium", tier: tier)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let screen = try await freshVoiceScreen(fixture, fastMode: fastMode)

        let context = try await screen.prepareRealtimeVoiceConversation()

        #expect(context.threadID == "voice-thread")
        #expect(context.model == CodexModelFixtures.solID)
        #expect(context.effort == "medium")
        #expect(context.fastModeSelection == fastMode)
        let start = try #require(await gateway.requests("thread/start").first?.objectValue)
        #expect(start["config"] == .object([
            "model_reasoning_effort": .string("medium"), "model_reasoning_summary": .string("detailed"),
        ]))
        #expect(await gateway.requests("conversation/settings/update").isEmpty)
        let saved = try #require(await screen.target.metadataService.metadata(for: "voice-thread"))
        #expect(saved.modelID == CodexModelFixtures.solID)
        #expect(saved.reasoningSelectionID == "effort-medium")
        #expect(saved.fastModeEnabled == fastMode)
        #expect(saved.source == .selection)
    }

    @Test func selectionChangedWhileTheVoiceThreadStartsGoesThroughTheSettingsQueue() async throws {
        let gateway = try await freshVoiceGateway(effort: "medium", tier: "priority")
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let screen = try await freshVoiceScreen(fixture, fastMode: true)
        await gateway.holdThreadStart()

        let preparation = Task { try await screen.prepareRealtimeVoiceConversation() }
        await gateway.waitForHeldThreadStart()
        screen.selectReasoning(.effort(.high), for: nil)
        screen.selectFastMode(false, for: nil)
        await gateway.releaseHeldThreadStart()
        let context = try await preparation.value

        #expect(context.effort == "high")
        #expect(context.fastModeSelection == false)
        let updates = await gateway.requests("conversation/settings/update")
        #expect(updates.count == 1)
        let update = try #require(updates.first?.objectValue)
        #expect(update["threadId"] == .string("voice-thread"))
        #expect(update["effort"] == .string("high"))
        #expect(update["serviceTier"] == .null)
        let saved = try #require(await screen.target.metadataService.metadata(for: "voice-thread"))
        #expect(saved.reasoningSelectionID == "effort-high")
        #expect(saved.fastModeEnabled == false)
    }

    @Test(arguments: ["xhigh", nil] as [String?])
    func voiceThreadReadbackThatDiffersFromTheSelectionAppliesTheSettingsUpdate(readback: String?) async throws {
        let gateway = try await freshVoiceGateway(effort: readback, tier: "priority")
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let screen = try await freshVoiceScreen(fixture, fastMode: true)

        let context = try await screen.prepareRealtimeVoiceConversation()

        #expect(context.effort == "medium")
        let updates = await gateway.requests("conversation/settings/update")
        #expect(updates.count == 1)
        let update = try #require(updates.first?.objectValue)
        #expect(update["effort"] == .string("medium"))
        #expect(update["serviceTier"] == .string("fast"))
    }

    @Test(arguments: [["Hello from the server", "Server reply"], []] as [[String]])
    func resumedVoiceCallWithNoLoadedMessagesStartsFromTheThreadsTail(serverMessages: [String]) async throws {
        let gateway = try await freshVoiceGateway(effort: "medium", tier: nil)
        await gateway.serveHistory(serverMessages.enumerated().map { index, text in
            .init(turnId: "t0", item: .agentMessage(id: "m\(index)", text: text),
                  startedAtOrdinal: Int64(index), isComplete: true)
        })
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let screen = try await freshVoiceScreen(fixture, fastMode: false)
        screen.setActiveSessionID("voice-thread")

        let context = try await screen.prepareRealtimeVoiceConversation()

        #expect(context.threadID == "voice-thread")
        #expect(!context.isProvisionalThread)
        #expect(context.history.map(\.text) == serverMessages)
        #expect(await gateway.tailReads == 1)
        #expect(await gateway.requests("thread/start").isEmpty)
    }

    @Test func resumedVoiceCallFailsWhenTheThreadsTailCannotBeRead() async throws {
        let gateway = try await freshVoiceGateway(effort: "medium", tier: nil)
        await gateway.failTailReads(true)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let screen = try await freshVoiceScreen(fixture, fastMode: false)
        screen.setActiveSessionID("voice-thread")

        await #expect(throws: (any Error).self) { try await screen.prepareRealtimeVoiceConversation() }
        #expect(screen.activeSessionID == "voice-thread")
    }
}

private actor SuspendedIncomingThreadRead {
    private var started: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<CodexAppServerV2.ThreadReadResponse, any Error>?

    func read() async throws -> CodexAppServerV2.ThreadReadResponse {
        try await withCheckedThrowingContinuation { continuation in
            response = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if response != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func complete(with value: CodexAppServerV2.ThreadReadResponse) {
        response?.resume(returning: value)
        response = nil
    }
}
