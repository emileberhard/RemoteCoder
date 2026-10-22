import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct CodexModelCatalogTests {
    private typealias Fixtures = CodexModelFixtures

    @Test func capabilitiesComeFromTheWireModel() throws {
        let catalog = try Fixtures.catalog()
        #expect(catalog.entries.map(\.id) == [Fixtures.astraID, Fixtures.solID, Fixtures.lunaID, Fixtures.sparkID, Fixtures.reserveID])
        #expect(catalog.entries.allSatisfy { $0.option.provider == .codex && $0.option.isListed })

        let astra = try #require(catalog.entry(for: Fixtures.astraID))
        #expect(astra.option.displayName == "GPT-6 Astra")
        #expect(astra.option.reasoningEfforts == ReasoningEffort.allCases)
        #expect(astra.option.supportsFastMode)
        #expect(astra.option.acceptsImages)
        #expect(astra.isUpstreamDefault && !astra.isHiddenUpstream)

        let luna = try #require(catalog.entry(for: Fixtures.lunaID))
        #expect(luna.option.supportsFastMode)

        let spark = try #require(catalog.entry(for: Fixtures.sparkID))
        #expect(spark.option.reasoningEfforts == [.low, .medium, .high, .xhigh])
        #expect(!spark.option.supportsFastMode)
        #expect(!spark.option.acceptsImages)

        #expect(catalog.entry(for: Fixtures.reserveID)?.isHiddenUpstream == true)
    }

    @Test func unknownInputModalitiesDoNotRejectTheModelList() throws {
        let wire = [
            Fixtures.wireModel("gpt-video", name: "Video", efforts: ["low"], inputModalities: ["text", "video"]),
            Fixtures.wireModel("gpt-hologram", name: "Hologram", efforts: ["low"], inputModalities: ["hologram", "image", "text"]),
        ]
        let catalog = CodexModelCatalog(models: try Fixtures.models(wire), fetchedAt: .now)
        #expect(catalog.entries.map(\.id) == ["gpt-video", "gpt-hologram"])
        #expect(catalog.entry(for: "gpt-video")?.option.acceptsImages == false)
        #expect(catalog.entry(for: "gpt-hologram")?.option.acceptsImages == true)
    }

    @Test func aRepeatedModelSlugKeepsItsFirstEntry() throws {
        let wire = Fixtures.wireModels() + [Fixtures.wireModel(Fixtures.solID, name: "Duplicate", efforts: ["low"])]
        let catalog = CodexModelCatalog(models: try Fixtures.models(wire), fetchedAt: .now)
        #expect(catalog.entries.filter { $0.id == Fixtures.solID }.map(\.option.displayName) == ["GPT-6.1 Sol"])
    }

    @Test func newModelsAreVisibleUnlessTheHostHidesThem() throws {
        let catalog = try Fixtures.catalog()
        let astra = try #require(catalog.entry(for: Fixtures.astraID))
        let reserve = try #require(catalog.entry(for: Fixtures.reserveID))
        var visibility = ModelVisibility.defaultValue
        #expect(catalog.visibleOptions(visibility).map(\.id) == [Fixtures.astraID, Fixtures.solID, Fixtures.lunaID, Fixtures.sparkID])

        visibility.setVisible(false, for: astra)
        visibility.setVisible(true, for: reserve)
        #expect(catalog.visibleOptions(visibility).map(\.id) == [Fixtures.solID, Fixtures.lunaID, Fixtures.sparkID, Fixtures.reserveID])
        #expect(visibility.rawValue == "-gpt-6-astra\n+gpt-reserve")
        #expect(ModelVisibility(rawValue: visibility.rawValue) == visibility)

        visibility.setVisible(true, for: astra)
        visibility.setVisible(false, for: reserve)
        #expect(visibility.rawValue.isEmpty)
    }

    @Test func newChatsUseTheSavedModelThenSolThenTheHostDefaultWithoutSwitchingProvider() throws {
        let catalog = try Fixtures.catalog()
        var hideSol = ModelVisibility.defaultValue
        hideSol.setVisible(false, for: try #require(catalog.entry(for: Fixtures.solID)))
        var hideSolAndAstra = hideSol
        hideSolAndAstra.setVisible(false, for: try #require(catalog.entry(for: Fixtures.astraID)))
        func resolve(
            _ id: String?, visibility: ModelVisibility = .defaultValue,
            providers: Set<AgentProvider> = Set(AgentProvider.allCases), codex: CodexModelCatalog? = catalog
        ) -> String? {
            NewChatModelResolution.model(preferredID: id, codex: codex, codexVisibility: visibility,
                                         claudeVisibility: .defaultValue, providers: providers)?.id
        }

        #expect(NewChatDefaults.initialCodexModelID == Fixtures.solID)
        #expect(resolve(Fixtures.lunaID) == Fixtures.lunaID)
        #expect(resolve(nil) == Fixtures.solID)
        #expect(resolve("gpt-retired") == Fixtures.solID)
        #expect(resolve(Fixtures.reserveID) == Fixtures.solID)
        #expect(resolve(nil, visibility: hideSol) == Fixtures.astraID)
        #expect(resolve(nil, visibility: hideSolAndAstra) == Fixtures.lunaID)
        #expect(resolve("opus") == "opus")
        #expect(resolve("opus", providers: [.codex]) == Fixtures.solID)
        #expect(resolve(Fixtures.lunaID, providers: [.claude]) == ClaudeModelCatalog.fableModelID)
        #expect(resolve(Fixtures.lunaID, codex: nil) == nil)

        let previousSolID = "gpt-6-sol"
        let withPreviousSol = CodexModelCatalog(models: try Fixtures.models(
            [Fixtures.wireModel(previousSolID, name: "GPT-6 Sol", efforts: ["low", "medium", "high"])] + Fixtures.wireModels()
        ), fetchedAt: .now)
        #expect(resolve(nil, codex: withPreviousSol) == Fixtures.solID)
        #expect(resolve(previousSolID, codex: withPreviousSol) == previousSolID)
    }

    @Test func cachedConstructionDefersDiskLoading() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "codex-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot: [String: Any] = ["models": Fixtures.wireModels(), "fetchedAt": 0]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: directory.appending(path: "codex-models.json"))
        let service = CodexModelCatalogService(directory: directory) { _ in throw URLError(.notConnectedToInternet) }

        #expect(service.catalog == nil, "Construction must leave an unread disk catalog unknown")
        await service.refresh()
        #expect(service.catalog?.entries.map(\.id) == [Fixtures.astraID, Fixtures.solID, Fixtures.lunaID, Fixtures.sparkID, Fixtures.reserveID])
        #expect(!service.hasFetched)
        #expect(service.refreshError != nil)
    }

    @Test func refreshFollowsCursorsPersistsAndReloadsTheList() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "codex-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var wire = Fixtures.wireModels()
        wire[0]["availableAccessPrograms"] = ["cyber": ["standard", "daybreakBlue"]]
        let models = try Fixtures.models(wire)
        let pages: [String?: CodexAppServerV2.ModelListResponse] = [
            nil: .init(data: Array(models.prefix(2)), nextCursor: "page-2"),
            "page-2": .init(data: Array(models.dropFirst(2)), nextCursor: nil),
        ]
        let service = CodexModelCatalogService(directory: directory) { cursor in
            guard let page = pages[cursor] else { throw URLError(.badServerResponse) }
            return page
        }
        #expect(service.catalog == nil)

        await service.refresh()

        #expect(service.refreshError == nil)
        #expect(service.hasFetched)
        #expect(service.catalog?.entries.map(\.id) == models.map(\.model))
        let reloaded = CodexModelCatalogService(directory: directory) { _ in throw URLError(.notConnectedToInternet) }
        await reloaded.restoreCachedCatalog()
        #expect(reloaded.catalog?.entries == service.catalog?.entries)
        #expect(!reloaded.hasFetched)
        #expect(reloaded.catalog?.entry(for: Fixtures.astraID)?.option.supportsDaybreakBlue == true)

        wire[0]["availableAccessPrograms"] = ["cyber": ["standard"]]
        let withoutAccess = try Fixtures.models(wire)
        let refreshed = CodexModelCatalogService(directory: directory) { _ in
            .init(data: withoutAccess, nextCursor: nil)
        }
        await refreshed.refresh()
        #expect(refreshed.refreshError == nil)
        #expect(refreshed.catalog?.entry(for: Fixtures.astraID)?.option.supportsDaybreakBlue == false)
    }

    @Test func failedEmptyOrEndlessRefreshKeepsTheLastGoodList() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "codex-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = try Fixtures.models()
        let good = CodexModelCatalogService(directory: directory) { _ in .init(data: models, nextCursor: nil) }
        await good.refresh()
        let entries = try #require(good.catalog?.entries)

        let failures: [(CodexModelCatalogService.PageLoader, String?)] = [
            ({ _ in .init(data: [], nextCursor: nil) }, CodexModelCatalogService.RefreshError.empty.errorDescription),
            ({ _ in .init(data: models, nextCursor: "same") }, CodexModelCatalogService.RefreshError.unfinishedPagination.errorDescription),
            ({ _ in throw URLError(.timedOut) }, nil),
        ]
        for (loader, message) in failures {
            let service = CodexModelCatalogService(directory: directory, loadPage: loader)
            await service.refresh()
            #expect(service.catalog?.entries == entries)
            #expect(service.refreshError != nil)
            if let message { #expect(service.refreshError == message) }
            #expect(!service.hasFetched)
        }
        let reloaded = CodexModelCatalogService(directory: directory) { _ in throw URLError(.timedOut) }
        await reloaded.restoreCachedCatalog()
        #expect(reloaded.catalog?.entries == entries)
    }

    @Test func cancelledCacheRestorationCanBeRetried() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "codex-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = try Fixtures.models()
        let original = CodexModelCatalogService(directory: directory) { _ in .init(data: models, nextCursor: nil) }
        await original.refresh()
        let cached = CodexModelCatalogService(directory: directory) { _ in throw URLError(.notConnectedToInternet) }
        let restoration = Task { await cached.restoreCachedCatalog() }
        restoration.cancel()
        await restoration.value

        #expect(cached.catalog == nil)
        await cached.restoreCachedCatalog()
        #expect(cached.catalog?.entries == original.catalog?.entries)
        #expect(!cached.hasFetched)
    }
}
