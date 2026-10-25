import Foundation
import Testing
@testable import RemoteCoderCore

struct ProviderHealthTests {
    private let native = ModelOption.unlisted(id: "gpt-6.1-sol", reportedEffort: nil, reportedFastMode: false)
    private let copilot = ModelOption(id: "copilot/gpt-6", displayName: "GPT-6", reasoningEfforts: [], supportsFastMode: false,
                                      supportsDaybreakBlue: false, acceptsImages: true, provider: .codex,
                                      modelProvider: .init(id: "copilot", name: "Copilot"), isListed: true)

    private func health(_ json: String) throws -> ProviderHealth {
        try JSONDecoder().decode(ProviderHealth.self, from: Data(json.utf8))
    }

    @Test func eachEntryDecodesOnItsOwnAndUnknownStatesStayUnknown() throws {
        let decoded = try health(#"""
        {"codex": {"state": "degraded", "reason": "future state"},
         "claude": {"state": "unavailable", "reason": "Claude Code is not signed in"},
         "gemini": {"state": "ready"}}
        """#)

        #expect(decoded.status(of: .codex) == nil)
        #expect(decoded.status(of: .claude) == .unavailable(reason: "Claude Code is not signed in"))
        #expect(try health(#"{"codex": {"state": "fallback", "reason": "no route"}}"#).status(of: .codex) == nil)
    }

    @Test func fallbackMarksOnlyNativeModelsAndWarnsNewChatsAboutTheRoute() throws {
        let decoded = try health(#"{"codex": {"state": "fallback", "reason": "Codex subscription sign-in failed", "fallback": "copilot"}}"#)

        #expect(decoded.isImpaired(native))
        #expect(!decoded.isImpaired(copilot))
        #expect(decoded.warning(for: native, isNewChat: true) == "New chats run on Copilot")
        #expect(decoded.warning(for: native, isNewChat: false) == "Codex subscription sign-in failed")
        #expect(decoded.warning(for: copilot, isNewChat: false) == nil)
        #expect(decoded.workingProviders == Set(AgentProvider.allCases))
    }

    @Test func anUnavailableProviderMarksAllItsModelsAndExplainsASwitchAway() throws {
        let decoded = try health(#"{"codex": {"state": "unavailable", "reason": "Codex sign-in needed on mac-mini"}, "claude": {"state": "ready"}}"#)
        let fable = try #require(ClaudeModelCatalog.model(for: "fable"))

        #expect(decoded.isImpaired(native) && decoded.isImpaired(copilot) && !decoded.isImpaired(fable))
        #expect(decoded.warning(for: native, isNewChat: true) == "Codex sign-in needed on mac-mini")
        #expect(decoded.switchNotice(preferred: .codex, selected: .claude) == "Codex sign-in needed on mac-mini")
        #expect(decoded.switchNotice(preferred: .claude, selected: .claude) == nil)
        #expect(decoded.workingProviders == [.claude])
    }
}
