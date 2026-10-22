import Foundation
import Testing
@testable import RemoteCoderCore

struct RealtimeVoiceContextTests {
    @Test func refreshedHistoryPreservesTheCallIdentityAndExecutionSettings() {
        let context = RealtimeVoiceConversationContext(
            threadID: "chat-a", realtimeSessionID: "call-a", isProvisionalThread: false,
            model: "gpt-5.6-sol", effort: "medium", cwd: "/project-a", fastModeState: .selection(true),
            history: [.init(role: .user, text: "Original request")]
        )
        let refreshed = context.refreshingHistory(
            chatMessages: [.init(role: .assistant, text: "Work finished")],
            voiceMessages: [.init(role: .user, text: "Follow up")]
        )
        #expect(refreshed.threadID == context.threadID)
        #expect(refreshed.realtimeSessionID == context.realtimeSessionID)
        #expect(refreshed.model == context.model)
        #expect(refreshed.effort == context.effort)
        #expect(refreshed.cwd == context.cwd)
        #expect(refreshed.fastModeSelection == context.fastModeSelection)
        #expect(refreshed.initialItems.map(\.text) == ["Work finished", "Follow up"])
    }

    @Test func provisionalReconnectKeepsItsContextBeforeARolloutExists() {
        let context = RealtimeVoiceConversationContext(
            threadID: "chat-a", realtimeSessionID: "call-a", isProvisionalThread: true,
            model: "sonnet", effort: "medium", cwd: "/project-a", fastModeState: .selection(nil),
            history: [.init(role: .user, text: "Voice-only request")]
        )
        let refreshed = context.refreshingHistory(chatMessages: [], voiceMessages: [])
        #expect(refreshed.initialItems.map(\.text) == ["Voice-only request"])
        #expect(refreshed.isProvisionalThread)
    }

    @Test(arguments: [
        (CodexModelFixtures.lunaID, FastModeState.selection(false), .clear),
        (CodexModelFixtures.sparkID, .selection(true), .clear),
        (CodexModelFixtures.astraID, .selection(true), .set(.fast)),
        (CodexModelFixtures.astraID, .readback(false, remembered: true), .clear),
        (CodexModelFixtures.astraID, .readback(nil, remembered: true), nil),
    ] as [(String, FastModeState, CodexAppServerV2.ServiceTierOverride?)])
    func liveSettingsEncodeTheFastChoiceWithoutChangingTheWorkspace(
        modelID: String, fastModeState: FastModeState, expected: CodexAppServerV2.ServiceTierOverride?
    ) throws {
        let model = try CodexModelFixtures.option(modelID)
        let request = ConversationSettingsUpdate(threadID: "chat-a", model: model,
            reasoning: .effort(.high), fastModeState: fastModeState)
        let value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(request.serviceTier == expected)
        switch expected {
        case nil: #expect(value["serviceTier"] == nil)
        case .clear: #expect(value["serviceTier"] is NSNull)
        case .set(let tier): #expect(value["serviceTier"] as? String == tier.rawValue)
        }
        #expect(value["effort"] as? String == "high")
        #expect(value["summary"] as? String == "detailed")
        #expect(value["cwd"] == nil)
        #expect(value["fastModeState"] == nil)
    }

    @Test func settingsAcknowledgedDuringHistoryRefreshSurviveTheOldSnapshot() throws {
        let luna = try CodexModelFixtures.option(CodexModelFixtures.lunaID)
        let captured = RealtimeVoiceConversationContext(
            threadID: "chat-a", realtimeSessionID: "call-a", isProvisionalThread: false,
            model: "gpt-5.6-sol", effort: "high", cwd: "/project-a", fastModeState: .selection(true),
            history: [.init(role: .user, text: "Original request")]
        )
        let applied = ConversationSettingsUpdate(threadID: "chat-a", model: luna,
            reasoning: .effort(.medium), fastModeState: .selection(false))
        let refreshed = captured.refreshingHistory(chatMessages: [.init(role: .assistant, text: "Still working")], voiceMessages: [])
            .applying(applied)
        #expect(refreshed.threadID == "chat-a")
        #expect(refreshed.realtimeSessionID == "call-a")
        #expect(refreshed.cwd == "/project-a")
        #expect(refreshed.model == luna.id)
        #expect(refreshed.effort == "medium")
        #expect(refreshed.fastModeSelection == false)
        #expect(ConversationSettingsUpdate(threadID: "chat-a", model: luna,
            reasoning: .effort(.medium), fastModeState: refreshed.fastModeState).serviceTier == .clear)
        #expect(refreshed.initialItems.map(\.text) == ["Still working"])
        let unrelated = ConversationSettingsUpdate(threadID: "chat-b", model: luna,
            reasoning: .effort(.high), fastModeState: .selection(true))
        #expect(refreshed.applying(unrelated).effort == "medium")
    }

    @Test(arguments: [
        ("{}", nil),
        ("{\"serviceTier\":null}", false),
        ("{\"serviceTier\":\"default\"}", false),
        ("{\"serviceTier\":\"priority\"}", true),
        ("{\"serviceTier\":\"fast\"}", true),
        ("{\"serviceTier\":\"flex\"}", nil),
    ] as [(String, Bool?)])
    func threadTierReadbackKeepsMissingUnknownAndNullStandard(json: String, expected: Bool?) throws {
        let extra = try JSONDecoder().decode(CodexAppServerV2.ThreadExtra.self, from: Data(json.utf8))
        #expect(extra.fastModeSelection == expected)
    }

    @Test func unsupportedVoiceModelPreservesFastPreferenceAcrossHistoryRefresh() throws {
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        let context = RealtimeVoiceConversationContext(
            threadID: "chat-a", realtimeSessionID: "call-a", isProvisionalThread: false,
            model: astra.id, effort: "high", cwd: "/project-a", fastModeState: .selection(true), history: []
        )
        let unsupported = context.applying(ConversationSettingsUpdate(
            threadID: "chat-a", model: spark, reasoning: .automatic, fastModeState: context.fastModeState
        )).refreshingHistory(chatMessages: [], voiceMessages: [])
        #expect(unsupported.fastModeSelection == true)
        #expect(ConversationSettingsUpdate(threadID: "chat-a", model: spark,
            reasoning: .automatic, fastModeState: unsupported.fastModeState).serviceTier == .clear)
        let restored = unsupported.applying(ConversationSettingsUpdate(
            threadID: "chat-a", model: astra, reasoning: .automatic,
            fastModeState: unsupported.fastModeState.changingModel(from: spark, to: astra)
        ))
        #expect(ConversationSettingsUpdate(threadID: "chat-a", model: astra,
            reasoning: .automatic, fastModeState: restored.fastModeState).serviceTier == .set(.fast))
    }

    @Test func offscreenVoiceReadbackKeepsTheRememberedFastChoiceThroughReasoningAndModelEdits() throws {
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        let context = RealtimeVoiceConversationContext(
            threadID: "call-thread", realtimeSessionID: "call-id", isProvisionalThread: false,
            model: spark.id, effort: "high", cwd: "/project-a",
            fastModeState: .readback(false, remembered: true), history: []
        )
        let reasoningEdit = context.applying(ConversationSettingsUpdate(
            threadID: context.threadID, model: spark, reasoning: .effort(.medium),
            fastModeState: context.fastModeState
        ))
        #expect(reasoningEdit.fastModeSelection == false)
        #expect(reasoningEdit.fastModeState.remembered == true)
        let notification = FastModeState.selection(true).observing(false)
        #expect(notification.selection == false)
        #expect(notification.remembered == true)
        let restored = reasoningEdit.applying(ConversationSettingsUpdate(
            threadID: context.threadID, model: astra, reasoning: .effort(.medium),
            fastModeState: reasoningEdit.fastModeState.changingModel(from: spark, to: astra)
        ))
        #expect(restored.fastModeSelection == true)
        #expect(restored.fastModeState.remembered == true)
        let reread = restored.fastModeState.reading(.init(serviceTier: "default"))
        #expect(reread.selection == false)
        #expect(reread.remembered == true)
        let explicitOff = restored.applying(ConversationSettingsUpdate(
            threadID: context.threadID, model: astra, reasoning: .effort(.medium),
            fastModeState: restored.fastModeState.choosing(false)
        ))
        #expect(explicitOff.fastModeSelection == false)
        #expect(explicitOff.fastModeState.remembered == false)
    }

}
