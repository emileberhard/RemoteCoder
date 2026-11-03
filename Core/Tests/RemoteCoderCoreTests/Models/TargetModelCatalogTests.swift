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
        let external = try #require(catalog.option(id: "relay/model-a", threadID: "t", modelProvider: nil, effort: nil, fastMode: false))
        let native = try #require(catalog.option(id: CodexModelFixtures.solID, threadID: "t", modelProvider: nil, effort: nil, fastMode: false))

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

    @Test func anUnlistedModelOnAnExternalRouteGetsAReadableNameAndItsProvider() throws {
        let defaults = try #require(UserDefaults(suiteName: "TargetModelCatalogTests.\(UUID())"))
        let service = CodexModelCatalogService(directory: .temporaryDirectory) { _ in throw URLError(.notConnectedToInternet) }
        let catalog = TargetModelCatalog(service: service, preferences: ModelPickerPreferences(defaults: defaults), defaults: defaults)
        let external = try #require(catalog.option(id: "copilot/gemini-4-argon", threadID: "t",
            modelProvider: .external(id: "copilot"), effort: "high", fastMode: false))
        let native = try #require(catalog.option(id: "copilot/gemini-4-argon", threadID: "t",
            modelProvider: .native, effort: nil, fastMode: false))

        #expect(external.pickerTitle == "Gemini 4 Argon · Copilot")
        #expect(external.reasoningEfforts == [.high])
        #expect(catalog.pickerOptions(including: external, threadModelProvider: .external(id: "copilot")).map(\.id)
            == ["copilot/gemini-4-argon"])
        #expect(native.pickerTitle == "copilot/gemini-4-argon")
        #expect(native.modelProvider == nil)
    }

    @Test func gatewayModelsKeepTheirHarnessAcrossDefaultsAndExistingThreads() async throws {
        let defaults = try #require(UserDefaults(suiteName: "TargetModelCatalogTests.\(UUID())"))
        var external = CodexModelFixtures.wireModel("relay/model-a", name: "Model A", efforts: ["low", "high"], inputModalities: ["text"])
        external["modelProvider"] = "relay"
        external["modelProviderName"] = "Relay"
        external["agentProvider"] = "claude"
        let models = try CodexModelFixtures.models(CodexModelFixtures.wireModels() + [external])
        let service = CodexModelCatalogService(directory: .temporaryDirectory.appending(path: UUID().uuidString)) { _ in
            CodexAppServerV2.ModelListResponse(data: models, nextCursor: nil)
        }
        await service.refresh()
        let preferences = ModelPickerPreferences(defaults: defaults)
        let catalog = TargetModelCatalog(service: service, preferences: preferences, defaults: defaults)
        NewChatDefaults.recordModelSelection("relay/model-a", defaults: defaults)

        let selected = try #require(catalog.newChatDefault(for: nil, health: nil).model)
        #expect(selected.provider == .claude)
        #expect(selected.modelProvider?.id == "relay")
        #expect(selected.reasoningEfforts == [.low, .high])
        #expect(!selected.acceptsImages)
        #expect(catalog.configured(id: selected.id).model == selected)
        let nativeClaudeUnavailable = ProviderHealth([.claude: .unavailable(reason: "Native sign-in needed")])
        #expect(catalog.newChatDefault(for: nil, health: nativeClaudeUnavailable).model == selected)
        #expect(!nativeClaudeUnavailable.isImpaired(selected))
        #expect(catalog.options(for: .claude).contains(selected))
        #expect(!catalog.options(for: .codex).contains(selected))
        #expect(catalog.pickerOptions(including: selected, threadModelProvider: .external(id: "relay")) == [selected])

        let existing = try #require(catalog.option(id: selected.id, threadID: "codex-existing", modelProvider: .external(id: "relay"), effort: "high", fastMode: false))
        #expect(existing.provider == .codex)
        #expect(!existing.isListed)
        #expect(existing.reasoningEfforts == [.high])
        let restored = try #require(catalog.option(id: selected.id, threadID: "claude_existing", modelProvider: .external(id: "relay"), effort: nil, fastMode: false))
        #expect(restored == selected)
        let unknown = try #require(catalog.option(id: "relay/removed", threadID: "claude_existing", modelProvider: .external(id: "relay"), effort: "high", fastMode: false))
        #expect(unknown.provider == .claude)
        #expect(unknown.modelProvider?.id == "relay")
        #expect(catalog.pickerOptions(including: unknown, threadModelProvider: .external(id: "relay")).map(\.id) == [selected.id, unknown.id])
        #expect(try JSONDecoder().decode(CodexAppServerV2.Model.self, from: JSONEncoder().encode(models.last)).agentProvider == .claude)
        #expect(models.first?.agentProvider == .codex)

        preferences.setModelVisible(false, for: try #require(service.catalog?.entry(for: selected.id)))
        #expect(!catalog.options(for: .claude).contains(selected))
        #expect(catalog.newChatDefault(for: nil, health: nil).model?.id == ClaudeModelCatalog.fableModelID)
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
        #expect(catalog.option(id: "claude-opus-5", threadID: "claude_existing", modelProvider: nil, effort: nil, fastMode: false) == opus)
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
