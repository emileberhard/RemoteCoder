import Foundation
import Testing
@testable import RemoteCoderCore

struct VoiceInitialThreadSettingsTests {
    private func start(_ model: ModelOption, effort: String?) -> RealtimeVoicePreparation.Start {
        .init(model: model, effort: effort, serviceTier: nil, fastMode: .selection(nil), settingsRevision: 0,
              hadPendingSettings: false, cwd: "/repo", history: [])
    }

    private func thread(id: String = "voice-thread", model: String?, effort: String?,
                        serviceTier: String?? = .none) throws -> CodexAppServerV2.Thread {
        var fields: [String: Any] = [
            "id": id, "preview": "", "modelProvider": "openai", "createdAt": 0, "updatedAt": 0, "cwd": "/repo",
            "cliVersion": "test", "source": "appServer", "status": ["type": "idle"], "ephemeral": false, "turns": [],
        ]
        fields["model"] = model
        fields["reasoningEffort"] = effort
        if case .some(let tier) = serviceTier { fields["extra"] = ["serviceTier": tier.map { $0 as Any } ?? NSNull()] }
        return try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func onlyAnExplicitCodexEffortStartsTheThreadWithReasoningConfig() throws {
        let sol = try CodexModelFixtures.option(CodexModelFixtures.solID)
        let claude = try #require(ClaudeModelCatalog.model(for: "sonnet"))
        #expect(start(sol, effort: "medium").initialThreadConfig == .init(modelReasoningEffort: .medium))
        #expect(start(sol, effort: nil).initialThreadConfig == nil)
        #expect(start(claude, effort: "high").initialThreadConfig == nil)
    }

    @Test(arguments: [
        (ReasoningSelection.effort(.medium), FastModeState.selection(nil), "gpt-6.1-sol", "medium", String??.none, true),
        (.effort(.medium), .selection(nil), "gpt-6.1-sol", "xhigh", .none, false),
        (.effort(.medium), .selection(nil), "gpt-6.1-sol", nil, .none, false),
        (.effort(.medium), .selection(nil), "gpt-5.6-luna", "medium", .none, false),
        (.automatic, .selection(nil), "gpt-6.1-sol", "medium", .none, false),
        (.effort(.medium), .selection(true), "gpt-6.1-sol", "medium", .some("priority"), true),
        (.effort(.medium), .selection(true), "gpt-6.1-sol", "medium", .none, false),
        (.effort(.medium), .selection(false), "gpt-6.1-sol", "medium", .some(nil), true),
        (.effort(.medium), .selection(false), "gpt-6.1-sol", "medium", .some("priority"), false),
    ] as [(ReasoningSelection, FastModeState, String, String?, String??, Bool)])
    func threadSelectionMatchRequiresTheReadBackModelEffortAndTier(
        reasoning: ReasoningSelection, fastMode: FastModeState, threadModel: String, threadEffort: String?,
        serviceTier: String??, matches: Bool
    ) throws {
        let sol = try CodexModelFixtures.option(CodexModelFixtures.solID)
        let settings = ConversationSettingsUpdate(threadID: "voice-thread", model: sol, reasoning: reasoning,
                                                  fastModeState: fastMode)
        #expect(settings.matchesThreadSelection(
            try thread(model: threadModel, effort: threadEffort, serviceTier: serviceTier)) == matches)
    }

    @Test func threadSelectionMatchNeverAcceptsAnotherThread() throws {
        let sol = try CodexModelFixtures.option(CodexModelFixtures.solID)
        let settings = ConversationSettingsUpdate(threadID: "voice-thread", model: sol, reasoning: .effort(.medium),
                                                  fastModeState: .selection(nil))
        #expect(!settings.matchesThreadSelection(try thread(id: "other-thread", model: sol.id, effort: "medium")))
    }
}
