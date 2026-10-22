import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct CodexModelsSettingsTests {
    @Test func unconfiguredCatalogRequiresAHost() async {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let settings = HostStore(hosts: [], activeHostID: nil, defaults: fixture.defaults,
                                 credentials: MemoryGatewayCredentials())
        let workspace = ChatWorkspaceModel(settings: settings, defaults: fixture.defaults,
            voiceCalls: TestVoiceCalls.center, makeBackgroundExecution: { StubBackgroundExecution() }, uploadContinuation: ForegroundUploadContinuation(),
            gatewayPolicy: .production, storage: fixture.temporaryStorage.storage)
        defer { await workspace.retireEverything() }

        if case .noHosts = workspace.codexModelCatalog {} else {
            Issue.record("An unconfigured catalog must ask for a host")
        }
    }

    @Test func availableSourceKeepsItsUnreadCatalogUnknown() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        try fixture.selectColdHost()
        guard case .available(let source) = fixture.workspace.codexModelCatalog else {
            Issue.record("A resolved host remains a valid source before its cache loads")
            return
        }
        let target = try #require(fixture.workspace.selectedScreen).target

        #expect(source.service === target.codexModels)
        #expect(source.service.catalog == nil)
    }
}
