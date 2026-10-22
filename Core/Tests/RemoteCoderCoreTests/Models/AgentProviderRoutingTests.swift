import Foundation
import Testing

@testable import RemoteCoderCore

struct AgentProviderRoutingTests {
    @Test(arguments: [
        ("claude-fable-5", "fable"),
        ("claude-opus-5", "opus"),
        ("claude-sonnet-5", "sonnet"),
        ("haiku", "haiku"),
        ("claude-haiku-5-5", "haiku"),
        ("claude-haiku-4-5-20251001", "haiku"),
    ])
    func savedClaudeModelsFollowTheirFamily(id: String, alias: String) throws {
        let defaults = try #require(UserDefaults(suiteName: "ModelAliasTests.\(UUID().uuidString)"))
        defer { defaults.removeObject(forKey: "codex.defaultModelID") }
        NewChatDefaults.recordModelSelection(id, defaults: defaults)
        let resolved = NewChatModelResolution.model(preferredID: NewChatDefaults.preferredModelID(defaults: defaults),
            codex: nil, codexVisibility: .defaultValue, claudeVisibility: .defaultValue, providers: Set(AgentProvider.allCases))
        #expect(resolved?.id == alias)
        #expect(ClaudeModelCatalog.model(for: id)?.id == alias)
        #expect(AgentProvider.provider(forModelID: id) == .claude)
    }

    @Test func threadIDPrefixDecidesTheProvider() {
        #expect(AgentProvider.provider(forThreadID: "claude_74625c52-f095-4eee") == .claude)
        #expect(AgentProvider.provider(forThreadID: "0199a1b2-c3d4-7e5f-8a9b") == .codex)
        // An empty id means "no thread yet", which is the Codex default path.
        #expect(AgentProvider.provider(forThreadID: "") == .codex)
    }

    @Test func anyIDOutsideTheClaudeFamiliesIsACodexModel() {
        #expect(AgentProvider.provider(forModelID: "gpt-6-astra") == .codex)
        #expect(AgentProvider.provider(forModelID: "a-model-released-tomorrow") == .codex)
    }
}
