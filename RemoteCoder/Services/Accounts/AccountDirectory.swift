import Foundation
import Observation

@Observable @MainActor
final class AccountDirectory {
    struct HostAccounts: Identifiable {
        let host: GatewayHostConfiguration
        var accounts: [ProviderAccountSnapshot] = []
        var error: String?
        var isRefreshing = false
        var id: UUID { host.id }
    }
    struct HostAccount: Identifiable, Equatable {
        let host: GatewayHostConfiguration
        let account: ProviderAccountSnapshot
        var id: String { "\(host.id.uuidString)|\(account.id)" }
    }
    struct AccountGroup: Identifiable, Equatable {
        let id: String
        let provider: AgentProvider
        let title: String
        let hosts: [HostAccount]
        let sample: ProviderAccountSnapshot

    }

    private(set) var hosts: [HostAccounts] = []
    private(set) var groups: [AccountGroup] = []
    let claude: ClaudeAccountDirectory
    let names: AccountNameStore
    let resetRedemptions: AccountResetRedemptions
    @ObservationIgnored private let store: AccountDirectoryStore
    @ObservationIgnored private var clients: [UUID: AccountAPIClient] = [:]
    @ObservationIgnored private let routes: @MainActor @Sendable (GatewayHostConfiguration) -> GatewayRoutes?
    @ObservationIgnored private var epochs: [UUID: UUID] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var taskIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var lastAttempt: [UUID: Date] = [:]
    @ObservationIgnored private var foreground: Task<Void, Never>?

    init(defaults: UserDefaults, storage: HostStorage = .live,
         beginBackgroundExecution: @escaping AccountResetRedemptions.BeginBackgroundExecution,
         routes: @escaping @MainActor @Sendable (GatewayHostConfiguration) -> GatewayRoutes?) {
        self.routes = routes
        claude = ClaudeAccountDirectory(storage: storage, beginBackgroundExecution: beginBackgroundExecution, routes: routes)
        resetRedemptions = AccountResetRedemptions(storage: storage, provider: .codex, beginBackgroundExecution: beginBackgroundExecution)
        store = AccountDirectoryStore(storage: storage)
        names = AccountNameStore(defaults: defaults)
        names.onRename = { [weak self] in self?.regroup() }
    }

    private func regroup() {
        let regrouped = Self.group(hosts, names: names)
        if groups != regrouped { groups = regrouped }
        resetRedemptions.retainAccounts(Set(regrouped.map(\.id)))
    }

    static func group(_ hosts: [HostAccounts], names: AccountNameStore) -> [AccountGroup] {
        let rows = hosts.flatMap { host in
            host.accounts.filter { $0.isDefault }.map { HostAccount(host: host.host, account: $0) }
        }
        // Unverified hosts remain distinct. A physical host does not add quota.
        let grouped = Dictionary(grouping: rows) { row in
            if row.account.provider == .claude { return "claude:\(row.host.id.uuidString)" }
            return row.account.identity.map { row.account.provider.groupID(for: $0) } ?? "\(row.account.provider.rawValue):\(row.id)"
        }
        return grouped.compactMap { key, rows -> AccountGroup? in
            guard let sample = rows.map(\.account).max(by: { left, right in
                if left.isUsable != right.isUsable { return !left.isUsable }
                if left.stale != right.stale { return left.stale }
                return (left.observedAt ?? 0) < (right.observedAt ?? 0)
            }) else { return nil }
            return AccountGroup(id: key, provider: sample.provider,
                                title: sample.provider == .claude ? rows[0].host.displayName : names.displayName(provider: sample.provider, identity: sample.identity),
                                hosts: rows.sorted { $0.id < $1.id }, sample: sample)
        }.sorted { left, right in
            if left.provider != right.provider { return left.provider.rawValue < right.provider.rawValue }
            if left.title != right.title { return left.title.localizedStandardCompare(right.title) == .orderedAscending }
            return left.id < right.id
        }
    }

    func reconcile(_ configured: [GatewayHostConfiguration]) {
        for previous in hosts where !configured.contains(where: { $0.id == previous.id && $0.hasSameConnection(as: previous.host) }) {
            resetRedemptions.retire(hostID: previous.id)
        }
        resetRedemptions.retainHosts(Set(configured.map(\.id)))
        if claude.reconcile(configured), foreground != nil { claude.requestRead() }
        let ids = Set(configured.map(\.id))
        for host in hosts where !ids.contains(host.id) {
            tasks.removeValue(forKey: host.id)?.cancel()
            clients.removeValue(forKey: host.id)
            epochs.removeValue(forKey: host.id)
            lastAttempt.removeValue(forKey: host.id)
        }
        hosts = configured.map { host in
            if let previous = hosts.first(where: { $0.id == host.id }), previous.host.hasSameConnection(as: host) {
                return HostAccounts(host: host, accounts: previous.accounts, error: previous.error,
                                    isRefreshing: previous.isRefreshing)
            }
            tasks.removeValue(forKey: host.id)?.cancel()
            clients[host.id] = AccountAPIClient(host: host) { [routes] in routes(host) }
            epochs[host.id] = UUID()
            lastAttempt.removeValue(forKey: host.id)
            return HostAccounts(host: host)
        }
        regroup()
    }

    func restore() async {
        await resetRedemptions.restore()
        await claude.resetRedemptions.restore()
        for hostID in hosts.map(\.id) {
            let epoch = epochs[hostID]
            guard let cached = await store.load(hostID: hostID), epochs[hostID] == epoch,
                  let index = hosts.firstIndex(where: { $0.id == hostID }), hosts[index].accounts.isEmpty else { continue }
            hosts[index].accounts = cached.accounts.filter(\.isDefault).map { account in
                var stale = account
                stale.stale = true
                return stale
            }
        }
        regroup()
    }

    func redeemReset(groupID: String, offer: AccountResetOffer) async {
        guard let group = groups.first(where: { $0.id == groupID }), group.provider == .codex,
              let row = group.hosts.first(where: { $0.account == group.sample }),
              !row.account.stale, row.account.resets?.state == .known,
              row.account.resets?.offers?.contains(offer) == true, offer.canUse(now: .now) else { return }
        await resetRedemptions.redeem(accountID: groupID, accountName: group.title, hostID: row.host.id,
            gatewayAccountID: row.account.id, offer: offer,
            operation: { [weak self] attempt in
                guard let self else { throw CancellationError() }
                let (client, account) = try resetSession(groupID: groupID, attempt: attempt)
                guard !account.stale, account.resets?.state == .known,
                      account.resets?.offers?.contains(offer) == true, offer.canUse(now: .now) else {
                    throw ResetRedemptionError.rejected("Reset offer changed. Refresh this account.")
                }
                try Task.checkCancellation()
                return try await client.redeemCodexReset(account: account, attempt: attempt)
            }, refresh: { [weak self] in await self?.refreshAfterReset(hostID: row.host.id) })
    }

    func retryReset(groupID: String) async {
        guard let attempt = resetRedemptions.states[groupID]?.attempt else { return }
        await resetRedemptions.retry(accountID: groupID,
            operation: { [weak self] attempt in
                guard let self else { throw CancellationError() }
                let (client, account) = try resetSession(groupID: groupID, attempt: attempt)
                try Task.checkCancellation()
                return try await client.redeemCodexReset(account: account, attempt: attempt)
            }, refresh: { [weak self] in await self?.refreshAfterReset(hostID: attempt.hostID) })
    }

    private func resetSession(groupID: String, attempt: ResetRedemptionAttempt) throws -> (AccountAPIClient, ProviderAccountSnapshot) {
        guard let host = hosts.first(where: { $0.id == attempt.hostID }),
              let account = host.accounts.first(where: { $0.id == attempt.gatewayAccountID && $0.provider == .codex }),
              account.identity.map({ AgentProvider.codex.groupID(for: $0) }) == groupID,
              let client = clients[attempt.hostID] else {
            throw AccountServiceError.rejected("Codex account unavailable.")
        }
        return (client, account)
    }

    private func refreshAfterReset(hostID: UUID) async {
        tasks.removeValue(forKey: hostID)?.cancel()
        taskIDs.removeValue(forKey: hostID)
        await refresh(hostID: hostID, interactive: true)
    }

    func refresh(interactive: Bool = false) async {
        async let claudeRefresh: Void = claude.refresh(interactive: interactive)
        await refreshCodex(interactive: interactive)
        await claudeRefresh
    }

    func refreshCodex(interactive: Bool) async {
        await resetRedemptions.restore()
        let ids = hosts.map(\.id)
        for offset in stride(from: 0, to: ids.count, by: 3) {
            let batch = Array(ids[offset..<min(ids.count, offset + 3)])
            await withTaskGroup(of: Void.self) { group in
                for id in batch { group.addTask { await self.refresh(hostID: id, interactive: interactive) } }
            }
        }
    }

    func refresh(hostID: UUID, interactive: Bool = false) async {
        if let task = tasks[hostID] { await task.value; return }
        guard let client = clients[hostID], let epoch = epochs[hostID] else { return }
        if !interactive, let last = lastAttempt[hostID], Date.now.timeIntervalSince(last) < 110 { return }
        lastAttempt[hostID] = .now
        let taskID = UUID()
        taskIDs[hostID] = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            setRefreshing(true, hostID: hostID)
            defer { if epochs[hostID] == epoch, taskIDs[hostID] == taskID { setRefreshing(false, hostID: hostID) } }
            do {
                let response = try await client.refreshedDirectory()
                try await accept(response, hostID: hostID, epoch: epoch)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, taskIDs[hostID] == taskID, epochs[hostID] == epoch,
                      let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
                var failed = hosts[index]
                failed.error = error.localizedDescription
                for account in failed.accounts.indices {
                    failed.accounts[account].stale = true
                    if failed.accounts[account].state == .ready { failed.accounts[account].state = .unavailable }
                }
                hosts[index] = failed
                regroup()
            }
        }
        tasks[hostID] = task
        await task.value
        if epochs[hostID] == epoch, taskIDs[hostID] == taskID {
            tasks.removeValue(forKey: hostID)
            taskIDs.removeValue(forKey: hostID)
        }
    }

    private func accept(_ received: AccountDirectoryResponse, hostID: UUID, epoch: UUID) async throws {
        try Task.checkCancellation()
        guard epochs[hostID] == epoch, let index = hosts.firstIndex(where: { $0.id == hostID }) else { throw CancellationError() }
        var response = received
        response.accounts = response.accounts.filter(\.isDefault)
        var updated = hosts[index]
        guard updated.accounts != response.accounts || updated.error != nil else { return }
        updated.accounts = response.accounts
        updated.error = nil
        hosts[index] = updated
        regroup()
        try await store.save(response, hostID: hostID)
    }

    private func setRefreshing(_ refreshing: Bool, hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[index].isRefreshing = refreshing
    }
    func routesBecameAvailable(for hostIDs: Set<UUID>) {
        guard foreground != nil, !hostIDs.isEmpty else { return }
        for hostID in hostIDs { lastAttempt.removeValue(forKey: hostID) }
        foreground?.cancel()
        foreground = nil
        startForeground()
    }

    func startForeground() {
        guard foreground == nil else { return }
        foreground = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
            }
        }
    }
    func stop() {
        stopForeground()
        resetRedemptions.stop()
        claude.resetRedemptions.stop()
    }

    func stopForeground() {
        claude.stopReading()
        foreground?.cancel(); foreground = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        taskIDs.removeAll()
        for index in hosts.indices { hosts[index].isRefreshing = false }
    }
}
