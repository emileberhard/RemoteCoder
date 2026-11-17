import Foundation
import Testing
@testable import RemoteCoderCore

struct RealtimeVoiceContextTests {
    @Test func refreshedHistoryPreservesTheCallIdentityAndExecutionSettings() {
        let context = RealtimeVoiceConversationContext(
            threadID: "chat-a", realtimeSessionID: "call-a", isProvisionalThread: false,
            model: "gpt-5.6-sol", effort: "medium", cwd: "/project-a", speedState: .selection(.fast),
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
            model: "sonnet", effort: "medium", cwd: "/project-a", speedState: .selection(nil),
            history: [.init(role: .user, text: "Voice-only request")]
        )
        let refreshed = context.refreshingHistory(chatMessages: [], voiceMessages: [])
        #expect(refreshed.initialItems.map(\.text) == ["Voice-only request"])
        #expect(refreshed.isProvisionalThread)
    }

    @Test(arguments: [
        (CodexModelFixtures.lunaID, ConversationSpeedState.selection(.standard), .clear),
        (CodexModelFixtures.sparkID, .selection(.fast), .clear),
        (CodexModelFixtures.astraID, .selection(.fast), .set(.fast)),
        (CodexModelFixtures.solID, .selection(.ultrafast), .set(.ultrafast)),
        (CodexModelFixtures.astraID, .readback(.standard, remembered: .fast), .clear),
        (CodexModelFixtures.astraID, .readback(nil, remembered: .fast), nil),
    ] as [(String, ConversationSpeedState, CodexAppServerV2.ServiceTierOverride?)])
    func liveSettingsEncodeTheFastChoiceWithoutChangingTheWorkspace(
        modelID: String, speedState: ConversationSpeedState, expected: CodexAppServerV2.ServiceTierOverride?
    ) throws {
        let model = try CodexModelFixtures.option(modelID)
        let request = ConversationSettingsUpdate(threadID: "chat-a", model: model,
            reasoning: .effort(.high), speedState: speedState)
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
        #expect(value["speedState"] == nil)
    }

    @Test func settingsAcknowledgedDuringHistoryRefreshSurviveTheOldSnapshot() throws {
        let luna = try CodexModelFixtures.option(CodexModelFixtures.lunaID)
        let captured = RealtimeVoiceConversationContext(
            threadID: "chat-a", realtimeSessionID: "call-a", isProvisionalThread: false,
            model: "gpt-5.6-sol", effort: "high", cwd: "/project-a", speedState: .selection(.fast),
            history: [.init(role: .user, text: "Original request")]
        )
        let applied = ConversationSettingsUpdate(threadID: "chat-a", model: luna,
            reasoning: .effort(.medium), speedState: .selection(.standard))
        let refreshed = captured.refreshingHistory(chatMessages: [.init(role: .assistant, text: "Still working")], voiceMessages: [])
            .applying(applied)
        #expect(refreshed.threadID == "chat-a")
        #expect(refreshed.realtimeSessionID == "call-a")
        #expect(refreshed.cwd == "/project-a")
        #expect(refreshed.model == luna.id)
        #expect(refreshed.effort == "medium")
        #expect(refreshed.fastModeSelection == false)
        #expect(ConversationSettingsUpdate(threadID: "chat-a", model: luna,
            reasoning: .effort(.medium), speedState: refreshed.speedState).serviceTier == .clear)
        #expect(refreshed.initialItems.map(\.text) == ["Still working"])
        let unrelated = ConversationSettingsUpdate(threadID: "chat-b", model: luna,
            reasoning: .effort(.high), speedState: .selection(.fast))
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
            model: astra.id, effort: "high", cwd: "/project-a", speedState: .selection(.fast), history: []
        )
        let unsupported = context.applying(ConversationSettingsUpdate(
            threadID: "chat-a", model: spark, reasoning: .automatic, speedState: context.speedState
        )).refreshingHistory(chatMessages: [], voiceMessages: [])
        #expect(unsupported.fastModeSelection == true)
        #expect(ConversationSettingsUpdate(threadID: "chat-a", model: spark,
            reasoning: .automatic, speedState: unsupported.speedState).serviceTier == .clear)
        let restored = unsupported.applying(ConversationSettingsUpdate(
            threadID: "chat-a", model: astra, reasoning: .automatic,
            speedState: unsupported.speedState.changingModel(from: spark, to: astra)
        ))
        #expect(ConversationSettingsUpdate(threadID: "chat-a", model: astra,
            reasoning: .automatic, speedState: restored.speedState).serviceTier == .set(.fast))
    }

    @Test func offscreenVoiceReadbackKeepsTheRememberedFastChoiceThroughReasoningAndModelEdits() throws {
        let spark = try CodexModelFixtures.option(CodexModelFixtures.sparkID)
        let astra = try CodexModelFixtures.option(CodexModelFixtures.astraID)
        let context = RealtimeVoiceConversationContext(
            threadID: "call-thread", realtimeSessionID: "call-id", isProvisionalThread: false,
            model: spark.id, effort: "high", cwd: "/project-a",
            speedState: .readback(.standard, remembered: .fast), history: []
        )
        let reasoningEdit = context.applying(ConversationSettingsUpdate(
            threadID: context.threadID, model: spark, reasoning: .effort(.medium),
            speedState: context.speedState
        ))
        #expect(reasoningEdit.fastModeSelection == false)
        #expect(reasoningEdit.speedState.remembered == .fast)
        let notification = ConversationSpeedState.selection(.fast).observing(.standard)
        #expect(notification.selection == .standard)
        #expect(notification.remembered == .fast)
        let restored = reasoningEdit.applying(ConversationSettingsUpdate(
            threadID: context.threadID, model: astra, reasoning: .effort(.medium),
            speedState: reasoningEdit.speedState.changingModel(from: spark, to: astra)
        ))
        #expect(restored.fastModeSelection == true)
        #expect(restored.speedState.remembered == .fast)
        let reread = restored.speedState.reading(.init(serviceTier: "default"))
        #expect(reread.selection == .standard)
        #expect(reread.remembered == .fast)
        let explicitOff = restored.applying(ConversationSettingsUpdate(
            threadID: context.threadID, model: astra, reasoning: .effort(.medium),
            speedState: restored.speedState.choosing(.standard)
        ))
        #expect(explicitOff.fastModeSelection == false)
        #expect(explicitOff.speedState.remembered == .standard)
    }

}
