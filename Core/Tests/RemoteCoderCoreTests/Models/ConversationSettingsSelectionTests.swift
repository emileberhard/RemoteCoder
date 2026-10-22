import Foundation
import Testing

@testable import RemoteCoderCore

struct ConversationSettingsSelectionTests {
    private static let codex = ModelOption(
        id: "gpt-a", displayName: "GPT A", reasoningEfforts: [.low, .high], supportsFastMode: true,
        supportsDaybreakBlue: false,
        acceptsImages: true, provider: .codex, isListed: true)
    private static let otherCodex = ModelOption(
        id: "gpt-b", displayName: "GPT B", reasoningEfforts: [.low, .high], supportsFastMode: false,
        supportsDaybreakBlue: false,
        acceptsImages: true, provider: .codex, isListed: true)

    private func fresh() -> ConversationSettingsSelection {
        ConversationSettingsSelection(model: Self.codex, reasoning: .automatic, fastMode: .selection(nil))
    }

    private func claude(_ id: String) throws -> ModelOption {
        try #require(ClaudeModelCatalog.model(for: id))
    }

    private func resolve(_ modelID: String, _ effort: String?, _ fastMode: Bool) -> ModelOption? {
        [Self.codex, Self.otherCodex].first { $0.id == modelID } ?? ClaudeModelCatalog.model(for: modelID)
    }

    @Test func choosingBumpsTheRevisionAndChoosingForAConversationMakesItReady() {
        var selection = fresh()
        selection.beginLoading()
        selection.choose(model: Self.otherCodex, reasoning: .effort(.high), fastMode: .selection(true))
        #expect(selection.revision == 1)
        #expect(selection.model == Self.otherCodex)
        #expect(selection.reasoning == .effort(.high))
        #expect(selection.fastMode == .selection(true))
        #expect(selection.isLoading)
        selection.chooseForConversation(model: Self.codex, reasoning: .automatic, fastMode: .selection(false))
        #expect(selection.revision == 2)
        #expect(selection.isReady)
    }

    @Test func adoptingAndRestoringNeverBumpTheRevision() {
        var selection = fresh()
        selection.adopt(model: Self.otherCodex, reasoning: .effort(.low), fastMode: .selection(false))
        selection.adoptModel(Self.codex)
        selection.restore(model: Self.otherCodex, reasoning: .automatic, fastMode: .selection(nil))
        #expect(selection.revision == 0)
        #expect(selection.model == Self.otherCodex)
    }

    @Test func observingBumpsTheRevisionOnlyWhenTheChoiceChanged() {
        var selection = fresh()
        selection.observe(model: Self.codex, reasoning: .effort(.high), reportedFastMode: true)
        #expect(selection.revision == 1)
        selection.observe(model: Self.codex, reasoning: .effort(.high), reportedFastMode: true)
        #expect(selection.revision == 1)
        #expect(selection.fastMode == .readback(true, remembered: nil))
        selection.observe(model: Self.codex, reasoning: .effort(.high), reportedFastMode: false)
        #expect(selection.revision == 2)
    }

    @Test func aTierReadbackIsAcceptedOnlyForTheRevisionItWasReadAt() {
        var selection = fresh()
        let extra = CodexAppServerV2.ThreadExtra(serviceTier: "priority")
        selection.choose(model: Self.codex, reasoning: .automatic, fastMode: .readback(nil, remembered: true))
        let staleRevision = selection.acceptTierReadback(extra, expectedRevision: 0)
        #expect(!staleRevision)
        let missingTier = selection.acceptTierReadback(nil, expectedRevision: 1)
        #expect(!missingTier)
        #expect(selection.fastMode == .readback(nil, remembered: true))
        let accepted = selection.acceptTierReadback(extra, expectedRevision: 1)
        #expect(accepted)
        #expect(selection.fastMode.selection == extra.fastModeSelection)
        #expect(selection.fastMode.remembered == true)
    }

    @Test func loadingFailsOnlyWhileLoading() {
        var selection = fresh()
        selection.failIfLoading("offline")
        #expect(selection.unavailableMessage == nil)
        selection.beginLoading()
        #expect(selection.fastMode == .readback(nil, remembered: nil))
        selection.failIfLoading("offline")
        #expect(selection.unavailableMessage == "offline")
        #expect(!selection.isReady)
        selection.markReady()
        #expect(selection.isReady)
    }

    @Test func aRecentCodexSelectionKeepsOnlyTheRememberedTier() throws {
        var selection = fresh()
        selection.showRecent(model: Self.codex, reasoning: .effort(.low), fastMode: .selection(true))
        #expect(selection.fastMode == .readback(nil, remembered: true))
        selection.showRecent(model: try claude(ClaudeModelCatalog.opusModelID), reasoning: .automatic, fastMode: .selection(false))
        #expect(selection.fastMode == .selection(false))
        #expect(selection.isReady)
    }

    @Test func onlyClaudeOpusSendsTheFastTier() throws {
        var selection = fresh()
        selection.choose(model: try claude(ClaudeModelCatalog.opusModelID), reasoning: .automatic, fastMode: .selection(true))
        #expect(selection.serviceTierOverride == .set(.fast))
        selection.choose(model: try claude(ClaudeModelCatalog.sonnetModelID), reasoning: .automatic, fastMode: .selection(true))
        #expect(selection.serviceTierOverride == .clear)
    }

    @Test func reasoningIsRememberedPerModel() {
        var selection = fresh()
        selection.remember(.effort(.high), for: Self.codex)
        #expect(selection.rememberedReasoning(for: Self.codex) == .effort(.high))
        #expect(selection.rememberedReasoning(for: Self.otherCodex) == nil)
    }

    @Test func aLoadedThreadRestoresWhatTheServerReports() throws {
        var selection = fresh()
        let thread = try ThreadFixture.basic("thread-1", updatedAt: 1000, fields: ["model": "gpt-b", "reasoningEffort": "high"])
        let saved = ConversationMetadata(sessionID: "thread-1", modelID: "gpt-b", reasoningSelectionID: "automatic",
                                         fastModeEnabled: true, source: .runtime, updatedAt: Date(timeIntervalSince1970: 2000))
        #expect(selection.restore(from: thread, saved: saved, resolveOption: resolve) == .thread)
        #expect(selection.model == Self.otherCodex)
        #expect(selection.reasoning == .automatic)
        #expect(selection.fastMode == .readback(nil, remembered: true))
        #expect(selection.revision == 0)
    }

    @Test func aServerReportedLevelReplacesAnyOtherSavedChoice() throws {
        var selection = fresh()
        let thread = try ThreadFixture.basic("thread-1", updatedAt: 1000, fields: ["model": "gpt-a", "reasoningEffort": "low"])
        let saved = ConversationMetadata(sessionID: "thread-1", modelID: "gpt-b", reasoningSelectionID: "automatic",
                                         source: .runtime, updatedAt: Date(timeIntervalSince1970: 2000))
        selection.restore(from: thread, saved: saved, resolveOption: resolve)
        #expect(selection.reasoning == .effort(.low))
    }

    @Test func anUnloadedClaudeThreadYieldsToANewerExplicitSelection() throws {
        var selection = fresh()
        let thread = try ThreadFixture.basic("claude_1", updatedAt: 1000, fields: ["model": "opus", "reasoningEffort": "low"])
        let saved = ConversationMetadata(sessionID: "claude_1", modelID: "sonnet", reasoningSelectionID: "effort-high",
                                         fastModeEnabled: false, source: .selection, updatedAt: Date(timeIntervalSince1970: 2000))
        #expect(selection.restore(from: thread, saved: saved, resolveOption: resolve) == .savedSelection)
        #expect(selection.model == (try claude(ClaudeModelCatalog.sonnetModelID)))
        #expect(selection.reasoning == .effort(.high))
        #expect(selection.fastMode == .selection(false))
    }

    @Test(arguments: [
        ("opus", nil, .effort(.high)),
        ("opus", "low", .effort(.low)),
        ("sonnet", nil, .automatic),
    ] as [(String, String?, ReasoningSelection)])
    func retainedObservedEffortIsUsedOnlyWhenThreadReadbackIsUnavailable(modelID: String, effort: String?, expected: ReasoningSelection) throws {
        var selection = fresh()
        var fields: [String: Any] = ["model": modelID]
        if let effort { fields["reasoningEffort"] = effort }
        let thread = try ThreadFixture.basic("claude_1", updatedAt: 1000, fields: fields)
        let observed = ConversationMetadata(sessionID: thread.id, modelID: "opus", reasoningSelectionID: "effort-high",
            updatedAt: Date(timeIntervalSince1970: 2000))
        #expect(selection.restore(from: thread, saved: observed, resolveOption: resolve) == .thread)
        #expect(selection.model == (try claude(modelID)))
        #expect(selection.reasoning == expected)
    }

    @Test func aModelThatDoesNotResolveLeavesTheSelectionUntouched() throws {
        var selection = fresh()
        let before = selection
        let thread = try ThreadFixture.basic("thread-1", updatedAt: 1000, fields: ["model": "gone"])
        #expect(selection.restore(from: thread, saved: nil, resolveOption: resolve) == nil)
        #expect(selection == before)
    }
}
