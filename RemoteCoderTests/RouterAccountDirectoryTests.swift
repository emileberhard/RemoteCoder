import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct RouterAccountDirectoryTests {
    @Test func appPreferencePublishesOnlyConfirmedResponseAndFailureKeepsOldAccount() async throws {
        let gateway = try FakeGatewayServer()
        let port = try await gateway.start()
        defer { Task { await gateway.stop() } }
        let host = GatewayHostConfiguration(id: UUID(), name: "Test gateway", hostname: "127.0.0.1", port: port,
                                            authToken: "test-token", transport: .trustedNetwork)
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = RouterAccountDirectory(storage: temporary.storage, beginBackgroundExecution: { _ in {} }, routes: GatewayRoutes.isolated)
        defer { directory.stopReading() }
        await gateway.setClaudeAccounts(list(selected: "one"), selection: list(selected: "two"), failsSelection: true)
        directory.reconcile([host])
        await directory.refresh(interactive: false)
        #expect(directory.state.preference == "one")
        await directory.select(.claude(.account("two")))
        #expect(directory.state.preference == "one")
        #expect(directory.error == "Preference could not be saved")
        await gateway.setClaudeAccounts(list(selected: "one"), selection: list(selected: "two"), failsSelection: false)
        await directory.select(.claude(.account("two")))
        #expect(directory.state.preference == "two")
        #expect(directory.error == nil)
        await directory.refresh(interactive: true)
        let requests = await gateway.routerHTTPRequests
        #expect(requests.map(\.path) == ["/claude/accounts", "/claude/accounts", "/claude/accounts/preference", "/claude/accounts", "/claude/accounts", "/claude/accounts/preference", "/claude/accounts/refresh"])
        let selection = try JSONDecoder().decode([String: String].self, from: requests[2].body)
        #expect(selection == ["account": "two"])
        #expect(requests[0].method == "GET")
        #expect(requests[2].method == "PUT")
        #expect(requests[6].method == "POST")
        #expect(String(data: requests[6].body, encoding: .utf8) == "{}")
    }

    @Test func explicitRefreshStillProbesWhenAReadIsAlreadyRunning() async throws {
        let gateway = try FakeGatewayServer()
        let port = try await gateway.start()
        defer { Task { await gateway.stop() } }
        await gateway.setClaudeAccounts(list(selected: "one"), selection: nil, failsSelection: false)
        await gateway.holdClaudeRead()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = RouterAccountDirectory(storage: temporary.storage, beginBackgroundExecution: { _ in {} }, routes: GatewayRoutes.isolated)
        defer { directory.stopReading() }
        directory.reconcile([GatewayHostConfiguration(id: UUID(), name: "Test gateway", hostname: "127.0.0.1",
            port: port, authToken: "test-token", transport: .trustedNetwork)])
        async let read: Void = directory.refresh(interactive: false)
        await gateway.waitForClaudeRead()
        async let refresh: Void = directory.refresh(interactive: true)
        await gateway.releaseClaudeRead()
        await read
        await refresh
        let requests = await gateway.routerHTTPRequests
        #expect(requests.map(\.path) == ["/claude/accounts", "/claude/accounts/refresh"])
    }

    @Test func partialHostFailureKeepsRouterAvailableAndRemovalIsAuthoritative() async throws {
        let first = try FakeGatewayServer()
        let second = try FakeGatewayServer()
        let firstPort = try await first.start()
        let secondPort = try await second.start()
        defer { Task { await first.stop(); await second.stop() } }
        await first.setClaudeAccounts(list(selected: "one"), selection: nil, failsSelection: false)
        await second.failClaudeRead(true)
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = RouterAccountDirectory(storage: temporary.storage, beginBackgroundExecution: { _ in {} }, routes: GatewayRoutes.isolated)
        defer { directory.stopReading() }
        directory.reconcile([configuration(name: "Mini", port: firstPort), configuration(name: "Book", port: secondPort)])
        await directory.refresh(interactive: false)
        #expect(directory.error == nil)
        #expect(directory.canSelect)
        let removed = ClaudeRouterAccountList(automatic: "two", preference: nil, accounts: [
            ClaudeRouterAccount(id: "two", label: "two@example.com", plan: "max", shared: false,
                credential: .rejected, availability: .unavailable, availableAt: nil, windows: [], observedAt: nil)
        ])
        await first.setClaudeAccounts(removed, selection: nil, failsSelection: false)
        await directory.refresh(interactive: false)
        #expect(directory.accounts.map(\.id) == ["two"])
        #expect(directory.effectiveAccount?.credential == .rejected)
        #expect(directory.error == nil)
        await first.failClaudeRead(true)
        await directory.refresh(interactive: false)
        #expect(directory.error == "Book: Router unavailable\nMini: Router unavailable")
        #expect(!directory.canSelect)
        #expect(directory.accounts.map(\.id) == ["two"])
    }

    @Test func renameKeepsRouteAndPreflightFallsBackWithoutRetryingSelection() async throws {
        let first = try FakeGatewayServer()
        let second = try FakeGatewayServer()
        let firstPort = try await first.start()
        let secondPort = try await second.start()
        defer { Task { await first.stop(); await second.stop() } }
        await first.setClaudeAccounts(list(selected: "one"), selection: list(selected: "two"), failsSelection: false)
        await second.setClaudeAccounts(list(selected: "one"), selection: list(selected: "two"), failsSelection: false)
        await second.failClaudeRead(true)
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = RouterAccountDirectory(storage: temporary.storage, beginBackgroundExecution: { _ in {} }, routes: GatewayRoutes.isolated)
        defer { directory.stopReading() }
        var preferred = configuration(name: "Mini", port: firstPort)
        let fallback = configuration(name: "Book", port: secondPort)
        directory.reconcile([preferred, fallback])
        await directory.refresh(interactive: false)
        preferred.name = "Renamed Mini"
        directory.reconcile([preferred, fallback])
        #expect(directory.canSelect)
        #expect(!directory.isRefreshing)
        await first.failClaudeRead(true)
        await second.failClaudeRead(false)
        await directory.select(.claude(.account("two")))
        #expect(directory.state.preference == "two")
        #expect(directory.error == nil)
        let firstRequests = await first.routerHTTPRequests
        let secondRequests = await second.routerHTTPRequests
        #expect(firstRequests.map(\.path) == ["/claude/accounts", "/claude/accounts"])
        #expect(secondRequests.map(\.path) == ["/claude/accounts", "/claude/accounts", "/claude/accounts/preference"])
    }

    @Test func lostSelectionResponseReconcilesCommittedSelectionWithoutAnotherPut() async throws {
        let gateway = try FakeGatewayServer()
        let port = try await gateway.start()
        defer { Task { await gateway.stop() } }
        await gateway.setClaudeAccounts(list(selected: "one"), selection: list(selected: "two"), failsSelection: false)
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = RouterAccountDirectory(storage: temporary.storage, beginBackgroundExecution: { _ in {} }, routes: GatewayRoutes.isolated)
        defer { directory.stopReading() }
        directory.reconcile([configuration(name: "Mini", port: port)])
        await directory.refresh(interactive: false)
        await gateway.dropClaudeSelectionResponse()
        await directory.select(.claude(.account("two")))
        #expect(directory.state.preference == "two")
        #expect(directory.error == nil)
        let requests = await gateway.routerHTTPRequests
        #expect(requests.filter { $0.path == "/claude/accounts/preference" }.count == 1)
        #expect(requests.last?.path == "/claude/accounts")
    }

    @Test func foregroundOwnerReadsConnectionEditsAndBackgroundReconciliationStaysOffline() async throws {
        let gateway = try FakeGatewayServer()
        let port = try await gateway.start()
        let temporary = TemporaryHostStorage()
        let owner = AccountDirectory(defaults: temporary.defaults, storage: temporary.storage, beginBackgroundExecution: { _ in {} }, routes: GatewayRoutes.isolated)
        let directory = owner.router
        defer { owner.stopForeground(); temporary.cleanUp(); Task { await gateway.stop() } }
        await gateway.setClaudeAccounts(list(selected: "one"), selection: nil, failsSelection: false)
        var host = configuration(name: "Mini", port: port)
        owner.reconcile([host])
        #expect(await waitUntil(timeout: .seconds(1)) { await gateway.connectionCount > 0 } == false)
        owner.startForeground()
        #expect(await waitUntil { directory.canSelect })
        #expect(await gateway.routerHTTPRequests.count == 1)
        await gateway.holdClaudeRead()
        host.authToken = "changed-token"
        owner.reconcile([host])
        await gateway.waitForClaudeRead()
        owner.stopForeground()
        #expect(!directory.isRefreshing)
        await gateway.releaseClaudeRead()
        host.authToken = "background-token"
        owner.reconcile([host])
        #expect(await waitUntil(timeout: .seconds(1)) { await gateway.routerHTTPRequests.count > 2 } == false)
        #expect(!directory.isRefreshing)
        await directory.select(.claude(.account("unknown")))
        #expect(directory.error == "Claude account unavailable.")
    }

    @Test func copilotRoutesAreOfferedOnlyWhenReportedAndConfirmedByTheirRoute() async throws {
        let gateway = try FakeGatewayServer()
        let port = try await gateway.start()
        defer { Task { await gateway.stop() } }
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = RouterAccountDirectory(storage: temporary.storage, beginBackgroundExecution: { _ in {} }, routes: GatewayRoutes.isolated)
        defer { directory.stopReading() }
        directory.reconcile([configuration(name: "Mini", port: port)])
        await gateway.setClaudeAccounts(list(selected: "one"), selection: nil, failsSelection: false)
        await directory.refresh(interactive: false)
        await directory.select(.claude(.copilot))
        #expect(directory.error == "Copilot unavailable.")
        var routed = list(selected: "one")
        routed.route = .subscription
        routed.codexRoute = .subscription
        routed.copilot = CopilotRouterAccount(label: "octo", plan: "business", availability: .available, availableAt: nil,
            error: nil, budget: .init(limitUsd: 150, spentUsd: 30, remainingUsd: 120, resetsAt: nil))
        var codex = routed
        codex.codexRoute = .copilot
        await gateway.setClaudeAccounts(routed, selection: codex, failsSelection: false)
        await directory.refresh(interactive: false)
        await directory.select(.codex(.copilot))
        #expect(directory.error == nil)
        #expect(directory.state.codexRoute == .copilot)
        #expect(directory.state.choice == .account("one"))
        let claude = ClaudeRouterAccountList(automatic: "one", preference: nil, accounts: codex.accounts,
            route: .copilot, codexRoute: .copilot, copilot: codex.copilot)
        await gateway.setClaudeAccounts(codex, selection: claude, failsSelection: false)
        await directory.select(.claude(.copilot))
        #expect(directory.error == nil)
        #expect(directory.state.choice == .copilot)
        #expect(directory.effectiveAccount == nil)
        let selections = await gateway.routerHTTPRequests.filter { $0.method == "PUT" }
        #expect(selections.map(\.path) == ["/codex/route", "/claude/accounts/preference"])
        #expect(try JSONDecoder().decode([String: String].self, from: selections[0].body) == ["route": "copilot"])
        #expect(try JSONDecoder().decode([String: String].self, from: selections[1].body) == ["account": "copilot"])
    }

    private func configuration(name: String, port: Int) -> GatewayHostConfiguration {
        GatewayHostConfiguration(id: UUID(), name: name, hostname: "127.0.0.1", port: port,
            authToken: "test-token", transport: .trustedNetwork)
    }

    private func list(selected: String) -> ClaudeRouterAccountList {
        ClaudeRouterAccountList(automatic: selected, preference: selected, accounts: ["one", "two"].map { id in
            ClaudeRouterAccount(id: id, label: "\(id)@example.com", plan: "max", shared: false,
                credential: .ready, availability: .available, availableAt: nil, windows: [], observedAt: nil)
        })
    }
}
