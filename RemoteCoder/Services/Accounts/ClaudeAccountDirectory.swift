import Foundation
import Observation

@Observable @MainActor
final class ClaudeAccountDirectory {
    private(set) var state = ClaudeRouterAccountState()
    private(set) var isRefreshing = false
    private(set) var isSelecting = false
    private(set) var error: String?
    let resetRedemptions: AccountResetRedemptions
    @ObservationIgnored private var hosts: [GatewayHostConfiguration] = []
    @ObservationIgnored private var clients: [UUID: AccountAPIClient] = [:]
    @ObservationIgnored private let routes: @MainActor @Sendable (GatewayHostConfiguration) -> GatewayRoutes?
    private var respondingHostID: UUID?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var refreshProbesUsage = false

    init(storage: HostStorage,
         beginBackgroundExecution: @escaping AccountResetRedemptions.BeginBackgroundExecution,
         routes: @escaping @MainActor @Sendable (GatewayHostConfiguration) -> GatewayRoutes?) {
        self.routes = routes
        resetRedemptions = AccountResetRedemptions(storage: storage, provider: .claude, beginBackgroundExecution: beginBackgroundExecution)
    }

    var accounts: [ClaudeRouterAccount] { state.accounts }
    var effectiveAccount: ClaudeRouterAccount? { accounts.first { $0.id == (state.preference ?? state.automatic) } }
    var canSelect: Bool { respondingHostID != nil && !isSelecting }

    @discardableResult
    func reconcile(_ configured: [GatewayHostConfiguration]) -> Bool {
        let connectionChanged = hosts.count != configured.count || configured.contains { host in
            !hosts.contains { $0.id == host.id && $0.hasSameConnection(as: host) }
        }
        guard connectionChanged else { hosts = configured; return false }
        stopReading()
        for previous in hosts where !configured.contains(where: { $0.id == previous.id && $0.hasSameConnection(as: previous) }) {
            resetRedemptions.retire(hostID: previous.id)
        }
        resetRedemptions.retainHosts(Set(configured.map(\.id)))
        if let respondingHostID,
           !configured.contains(where: { host in
               host.id == respondingHostID && hosts.contains { $0.id == host.id && $0.hasSameConnection(as: host) }
           }) { self.respondingHostID = nil }
        clients = Dictionary(uniqueKeysWithValues: configured.map { host in
            let retained = hosts.contains { $0.id == host.id && $0.hasSameConnection(as: host) }
            return (host.id, retained ? clients[host.id] ?? client(for: host) : client(for: host))
        })
        hosts = configured
        if configured.isEmpty {
            state = ClaudeRouterAccountState()
            resetRedemptions.retainAccounts([])
            error = nil
        }
        return true
    }

    func requestRead() {
        guard !hosts.isEmpty, !isSelecting, task == nil else { return }
        _ = startRefresh(interactive: false)
    }

    func refresh(interactive: Bool) async {
        await resetRedemptions.restore()
        guard !hosts.isEmpty else { error = "No gateway is available for Claude accounts."; return }
        guard !isSelecting else { return }
        if let task {
            let fence = revision
            let needsProbe = interactive && !refreshProbesUsage
            await task.value
            guard needsProbe, !Task.isCancelled, revision == fence, !isSelecting else { return }
            await refresh(interactive: true)
            return
        }
        await startRefresh(interactive: interactive).value
    }

    private func startRefresh(interactive: Bool) -> Task<Void, Never> {
        let fence = revision
        let operationID = UUID()
        self.operationID = operationID
        refreshProbesUsage = interactive
        isRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, revision == fence, self.operationID == operationID else { return }
            defer { finish(operationID: operationID, fence: fence) }
            var failures: Set<String> = []
            var succeeded = false
            let configured = hosts
            for offset in stride(from: 0, to: configured.count, by: 3) {
                let batch = configured[offset..<min(configured.count, offset + 3)]
                await withTaskGroup(of: (GatewayHostConfiguration, Result<ClaudeRouterAccountList, Error>).self) { group in
                    for host in batch {
                        guard let client = clients[host.id] else {
                            failures.insert("\(host.displayName): Gateway unavailable")
                            continue
                        }
                        group.addTask {
                            do {
                                let response = try await (interactive ? client.refreshClaudeAccounts() : client.claudeAccounts())
                                return (host, .success(response))
                            } catch { return (host, .failure(error)) }
                        }
                    }
                    for await (host, result) in group {
                        guard !Task.isCancelled, revision == fence else { group.cancelAll(); return }
                        do {
                            try state.accept(result.get())
                            respondingHostID = host.id
                            succeeded = true
                        } catch is CancellationError { continue }
                        catch { failures.insert("\(host.displayName): \(error.localizedDescription)") }
                    }
                }
                guard !Task.isCancelled, revision == fence else { return }
            }
            if succeeded {
                error = nil
                resetRedemptions.retainAccounts(Set(accounts.map(\.id)))
            }
            else {
                respondingHostID = nil
                error = failures.isEmpty ? "No gateway is available for Claude accounts." : failures.sorted().joined(separator: "\n")
            }
        }
        self.task = task
        return task
    }

    func setPreference(_ id: String?) async {
        guard !isSelecting else { error = "An account selection is already in progress."; return }
        guard id == nil || accounts.contains(where: { $0.id == id }) else { error = "Claude account unavailable."; return }
        guard !hosts.isEmpty else { error = "No gateway is available for Claude account selection."; return }
        stopReading()
        let fence = revision
        let operationID = UUID()
        self.operationID = operationID
        isSelecting = true
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, revision == fence, self.operationID == operationID else { return }
            defer { finish(operationID: operationID, fence: fence) }
            let candidates = hosts.filter { $0.id == respondingHostID } + hosts.filter { $0.id != respondingHostID }
            var failures: Set<String> = []
            for host in candidates {
                guard !Task.isCancelled, revision == fence else { return }
                guard let client = clients[host.id] else {
                    failures.insert("\(host.displayName): Gateway unavailable")
                    continue
                }
                let available: ClaudeRouterAccountList
                do { available = try await client.claudeAccounts() }
                catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, revision == fence else { return }
                    failures.insert("\(host.displayName): \(error.localizedDescription)")
                    continue
                }
                guard !Task.isCancelled, revision == fence else { return }
                do { try state.accept(available) }
                catch { self.error = error.localizedDescription; return }
                respondingHostID = host.id
                guard id == nil || available.accounts.contains(where: { $0.id == id }) else {
                    error = "Claude account unavailable."
                    return
                }
                do {
                    let response = try await client.setClaudePreference(id)
                    guard !Task.isCancelled, revision == fence else { return }
                    guard response.preference == id else { throw AccountServiceError.invalidResponse }
                    try state.accept(response)
                    error = nil
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, revision == fence else { return }
                    let selectionError = error.localizedDescription
                    let readbackHosts = [host] + candidates.filter { $0.id != host.id }
                    for readbackHost in readbackHosts {
                        guard !Task.isCancelled, revision == fence else { return }
                        guard let readback = clients[readbackHost.id] else {
                            failures.insert("\(readbackHost.displayName): Gateway unavailable")
                            continue
                        }
                        do {
                            let confirmed = try await readback.claudeAccounts()
                            guard !Task.isCancelled, revision == fence else { return }
                            try state.accept(confirmed)
                            respondingHostID = readbackHost.id
                            self.error = confirmed.preference == id ? nil : selectionError
                            return
                        } catch is CancellationError { return }
                        catch { failures.insert("\(readbackHost.displayName): \(error.localizedDescription)") }
                    }
                    guard !Task.isCancelled, revision == fence else { return }
                    respondingHostID = nil
                    self.error = ([selectionError] + failures.sorted()).joined(separator: "\n")
                }
                return
            }
            respondingHostID = nil
            error = failures.isEmpty ? "No gateway is available for Claude accounts." : failures.sorted().joined(separator: "\n")
        }
        self.task = task
        await task.value
    }

    private func finish(operationID: UUID, fence: UUID) {
        guard revision == fence, self.operationID == operationID else { return }
        task = nil
        self.operationID = nil
        isRefreshing = false
        isSelecting = false
    }

    func stopReading() {
        revision = UUID()
        task?.cancel()
        task = nil
        operationID = nil
        isRefreshing = false
        isSelecting = false
    }

    func redeemReset(accountID: String, offer: AccountResetOffer) async {
        guard let account = accounts.first(where: { $0.id == accountID }),
              account.resets?.isStale(now: .now) == false,
              account.resets?.offers?.contains(offer) == true, offer.canUse(now: .now),
              let hostID = respondingHostID else { return }
        await resetRedemptions.redeem(accountID: accountID, accountName: account.label, hostID: hostID, gatewayAccountID: account.id, offer: offer,
            operation: { [weak self] attempt in
                guard let self else { throw CancellationError() }
                guard let current = accounts.first(where: { $0.id == attempt.gatewayAccountID }),
                      current.resets?.isStale(now: .now) == false,
                      current.resets?.offers?.contains(offer) == true, offer.canUse(now: .now) else {
                    throw ResetRedemptionError.rejected("Reset offer changed. Refresh this account.")
                }
                return try await submitReset(attempt: attempt)
            }, refresh: { [weak self] in await self?.refreshAfterReset() })
    }

    func retryReset(accountID: String) async {
        await resetRedemptions.retry(accountID: accountID,
            operation: { [weak self] attempt in
                guard let self else { throw CancellationError() }
                return try await submitReset(attempt: attempt)
            }, refresh: { [weak self] in await self?.refreshAfterReset() })
    }

    private func submitReset(attempt: ResetRedemptionAttempt) async throws -> AccountResetRedemptionResult {
        guard accounts.contains(where: { $0.id == attempt.gatewayAccountID }), let client = clients[attempt.hostID] else {
            throw AccountServiceError.rejected("Claude account unavailable.")
        }
        try Task.checkCancellation()
        return try await client.redeemClaudeReset(accountID: attempt.gatewayAccountID, attempt: attempt)
    }

    private func refreshAfterReset() async {
        if !isSelecting { stopReading() }
        if let task { await task.value }
        await refresh(interactive: true)
    }

    private func client(for host: GatewayHostConfiguration) -> AccountAPIClient {
        AccountAPIClient(host: host) { [routes] in routes(host) }
    }
}
