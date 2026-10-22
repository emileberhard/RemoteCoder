import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ModelPickerPreferencesTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ModelPickerPreferencesTests.\(UUID())"))
    }

    @Test func hidingAnEffortPersistsItAndNotifiesOnceWithTheUnchangedModelVisibility() throws {
        let defaults = try defaults()
        let preferences = ModelPickerPreferences(defaults: defaults)
        var notifications: [ModelVisibility] = []
        var providers: [AgentProvider] = []
        preferences.onChange = { provider, previous in
            providers.append(provider)
            notifications.append(previous)
        }

        preferences.setVisible(.xhigh, false, for: .codex)
        preferences.setVisible(.xhigh, false, for: .codex)

        #expect(notifications == [preferences.codexModelVisibility])
        #expect(providers == [.codex])
        #expect(!preferences.isVisible(.xhigh, for: .codex))
        #expect(preferences.isVisible(.xhigh, for: .claude))
        #expect(!ModelPickerPreferences(defaults: defaults).isVisible(.xhigh, for: .codex))
    }

    @Test(arguments: [
        (AgentProvider.codex, CodexModelFixtures.solID, CodexModelFixtures.solID),
        (.claude, "claude-opus-5", "opus"),
        (.claude, "claude-haiku-5-5", "haiku"),
    ])
    func hidingAModelPersistsOnlyForItsProviderAndNotifiesOnce(provider: AgentProvider, modelID: String, id: String) throws {
        let defaults = try defaults()
        defaults.set("+gpt-reserve", forKey: "codex.modelVisibility")
        let catalog = try CodexModelFixtures.catalog()
        let sol = try #require(catalog.entry(for: CodexModelFixtures.solID))
        let preferences = ModelPickerPreferences(defaults: defaults)
        let before = preferences.modelVisibility(for: provider)
        let other: AgentProvider = provider == .codex ? .claude : .codex
        let otherBefore = preferences.modelVisibility(for: other)
        var notifications: [ModelVisibility] = []
        var providers: [AgentProvider] = []
        preferences.onChange = { provider, previous in
            providers.append(provider)
            notifications.append(previous)
        }

        for _ in 0..<2 {
            switch provider {
            case .codex: preferences.setModelVisible(false, for: sol)
            case .claude: preferences.setClaudeModelVisible(false, id: modelID)
            }
        }

        #expect(notifications == [before])
        #expect(providers == [provider])
        #expect(before.isVisible(id: id))
        #expect(!preferences.modelVisibility(for: provider).isVisible(id: id))
        let reloaded = ModelPickerPreferences(defaults: defaults)
        #expect(!reloaded.modelVisibility(for: provider).isVisible(id: id))
        #expect(reloaded.modelVisibility(for: other) == otherBefore)
        #expect(reloaded.codexModelVisibility.isVisible(try #require(catalog.entry(for: "gpt-reserve"))))
    }

    @Test func clampingUsesTheVisibleEffortsOfTheModelsOwnProvider() throws {
        let preferences = ModelPickerPreferences(defaults: try defaults())
        let astra = try #require(CodexModelFixtures.catalog().entry(for: CodexModelFixtures.astraID)).option
        for effort in ReasoningEffort.allCases where effort != .medium {
            preferences.setVisible(effort, false, for: .codex)
        }

        #expect(preferences.reasoningEfforts(for: astra) == [.medium])
        #expect(preferences.clamped(.effort(.xhigh), for: astra) == .effort(.medium))
        #expect(preferences.clamped(.automatic, for: astra) == .automatic)
    }
}
