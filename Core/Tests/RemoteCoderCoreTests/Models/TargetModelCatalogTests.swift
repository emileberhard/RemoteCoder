import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct TargetModelCatalogTests {
    @Test func anUnreadCodexChoiceDoesNotClaimClaudeModelsAreHidden() throws {
        let defaults = try #require(UserDefaults(suiteName: "TargetModelCatalogTests.\(UUID())"))
        NewChatDefaults.recordModelSelection(ClaudeModelCatalog.fableModelID, defaults: defaults)
        let preferences = ModelPickerPreferences(defaults: defaults)
        let service = CodexModelCatalogService(directory: .temporaryDirectory) { _ in throw URLError(.notConnectedToInternet) }
        let catalog = TargetModelCatalog(service: service, preferences: preferences, defaults: defaults)

        #expect(catalog.newChatDefault(for: .codex, health: nil) == .listNotLoaded)
        #expect(catalog.newChatUnavailableReason(for: .codex) == "Codex models haven't loaded yet.")
        #expect(!catalog.options(for: .claude).isEmpty)
    }

    @Test func anExistingConversationOffersOnlyModelsOfItsModelProvider() async throws {
        let defaults = try #require(UserDefaults(suiteName: "TargetModelCatalogTests.\(UUID())"))
        var relay = CodexModelFixtures.wireModel("relay/model-a", name: "Model A", efforts: ["low", "medium", "high"])
        relay["modelProvider"] = "relay"
        relay["modelProviderName"] = "Relay"
        let models = try CodexModelFixtures.models(CodexModelFixtures.wireModels() + [relay])
        let service = CodexModelCatalogService(directory: .temporaryDirectory.appending(path: UUID().uuidString)) { _ in
            CodexAppServerV2.ModelListResponse(data: models, nextCursor: nil)
        }
        await service.refresh()
        let catalog = TargetModelCatalog(service: service, preferences: ModelPickerPreferences(defaults: defaults), defaults: defaults)
        let external = try #require(catalog.option(id: "relay/model-a", threadID: "t", effort: nil, fastMode: false))
        let native = try #require(catalog.option(id: CodexModelFixtures.solID, threadID: "t", effort: nil, fastMode: false))

        #expect(external.pickerTitle == "Model A · Relay")
        #expect(native.pickerTitle == "GPT-6.1 Sol")
        #expect(catalog.options(for: .codex).contains(external), "new chats offer every provider")
        #expect(catalog.pickerOptions(including: external, threadModelProvider: nil).map(\.id) == ["relay/model-a"])
        #expect(!catalog.pickerOptions(including: native, threadModelProvider: nil).contains { $0.modelProvider != nil })
        #expect(catalog.pickerOptions(including: native, threadModelProvider: .external(id: "relay")).map(\.id)
            == ["relay/model-a", CodexModelFixtures.solID], "a thread started natively but running on Relay offers Relay's models")

        let encoded = try JSONEncoder().encode(models.last)
        #expect(try JSONDecoder().decode(CodexAppServerV2.Model.self, from: encoded).modelProvider == external.modelProvider)
    }

    @Test func hiddenClaudeModelsLeavePickersAndDefaultsButKeepTheirIdentity() throws {
        let defaults = try #require(UserDefaults(suiteName: "TargetModelCatalogTests.\(UUID())"))
        let preferences = ModelPickerPreferences(defaults: defaults)
        let catalog = TargetModelCatalog(service: CodexModelCatalogService(directory: .temporaryDirectory) { _ in throw URLError(.notConnectedToInternet) }, preferences: preferences, defaults: defaults)
        let opus = try #require(ClaudeModelCatalog.model(for: "opus"))
        NewChatDefaults.recordModelSelection("claude-opus-5", defaults: defaults)
        #expect(catalog.newChatDefault(for: nil, health: nil).model == opus)

        preferences.setClaudeModelVisible(false, id: opus.id)
        #expect(catalog.options(for: .claude).map(\.id) == ["fable", "sonnet", "haiku"])
        #expect(catalog.newChatDefault(for: nil, health: nil).model?.id == "fable")
        #expect(catalog.configured(id: "claude-opus-5").model == opus)
        #expect(catalog.option(id: "claude-opus-5", threadID: "claude_existing", effort: nil, fastMode: false) == opus)
        #expect(catalog.pickerOptions(including: opus, threadModelProvider: nil).map(\.id) == ["fable", "sonnet", "haiku", "opus"])

        preferences.setClaudeModelVisible(false, id: "fable")
        #expect(catalog.defaultModel(for: .claude)?.id == "sonnet")
        preferences.setClaudeModelVisible(false, id: "sonnet")
        #expect(catalog.defaultModel(for: .claude)?.id == "haiku")
        preferences.setClaudeModelVisible(false, id: "claude-haiku-5-5")
        #expect(catalog.options(for: .claude).isEmpty)
        #expect(catalog.defaultModel(for: .claude) == nil)
        #expect(catalog.newChatDefault(for: nil, health: nil) == .notOffered)
        #expect(catalog.newChatUnavailableReason(for: nil).contains("Claude Code"))
        #expect(catalog.configured(id: "opus").model == opus)
        #expect(NewChatDefaults.preferredModelID(defaults: defaults) == "claude-opus-5")

        preferences.setClaudeModelVisible(true, id: "opus")
        #expect(catalog.newChatDefault(for: nil, health: nil).model == opus)
    }

    @Test func aNewChatStartsOnAWorkingProviderWhileTheDefaultOneIsUnavailable() async throws {
        let defaults = try #require(UserDefaults(suiteName: "TargetModelCatalogTests.\(UUID())"))
        let models = try CodexModelFixtures.models()
        let service = CodexModelCatalogService(directory: .temporaryDirectory.appending(path: UUID().uuidString)) { _ in
            CodexAppServerV2.ModelListResponse(data: models, nextCursor: nil)
        }
        await service.refresh()
        let catalog = TargetModelCatalog(service: service, preferences: ModelPickerPreferences(defaults: defaults), defaults: defaults)
        let codexDown = ProviderHealth([.codex: .unavailable(reason: "Codex sign-in needed"), .claude: .ready])
        let bothDown = ProviderHealth([.codex: .unavailable(reason: "Codex sign-in needed"), .claude: .unavailable(reason: "Claude signed out")])
        let fallback = ProviderHealth([.codex: .fallback(route: "copilot", reason: "Codex subscription sign-in failed")])

        #expect(catalog.newChatDefault(for: nil, health: nil).model?.provider == .codex)
        #expect(catalog.newChatDefault(for: nil, health: codexDown).model?.provider == .claude)
        #expect(catalog.newChatDefault(for: nil, health: fallback).model?.provider == .codex)
        #expect(catalog.newChatDefault(for: nil, health: bothDown).model?.provider == .codex)
        #expect(catalog.newChatDefault(for: .codex, health: codexDown).model?.provider == .codex, "an explicit provider stays")

        NewChatDefaults.recordModelSelection("opus", defaults: defaults)
        let claudeDown = ProviderHealth([.claude: .unavailable(reason: "Claude signed out")])
        #expect(catalog.newChatDefault(for: nil, health: claudeDown).model?.provider == .codex)
        NewChatDefaults.recordModelSelection(CodexModelFixtures.solID, defaults: defaults)
        for id in ["fable", "opus", "sonnet", "haiku"] { catalog.preferences.setClaudeModelVisible(false, id: id) }
        #expect(catalog.newChatDefault(for: nil, health: codexDown).model?.provider == .codex, "no working model keeps the default")
    }
}
