import Foundation
import Observation

@Observable @MainActor
final class ConversationAgentsModel: Identifiable {
    static let recentWindow: TimeInterval = 12 * 60 * 60

    let id = UUID()
    let address: ConversationAddress
    var threadID: String { address.threadID }
    @ObservationIgnored private let gateway: GatewayClient
    private(set) var agents: [ConversationAgent] = []
    private(set) var sections = ConversationAgentSections.empty
    private(set) var warnings: [String] = []
    private(set) var error: String?
    private(set) var hasLoaded = false
    private(set) var coverage: [ClusterCoverage] = []
    @ObservationIgnored var clusterHosts: @MainActor () -> [ConversationAgentsHost] = { [] }
    @ObservationIgnored var knownCoverage: @MainActor () -> [ClusterCoverage] = { [] }
    @ObservationIgnored private var rowsByHost: [UUID: [ConversationAgent]] = [:]
    @ObservationIgnored private var warningsByHost: [UUID: [String]] = [:]
    @ObservationIgnored private var successfulReads: [UUID: Date] = [:]
    private(set) var isRefreshing = false
    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var observedChildren: Set<String>?
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var summary: ConversationAgentSummary? {
        hasLoaded ? ConversationAgentSummary(total: agents.count, recent: sections.recent.count) : nil
    }

    init(address: ConversationAddress, gateway: GatewayClient, now: @escaping @Sendable () -> Date = { .now }) {
        self.address = address
        self.gateway = gateway
        self.now = now
    }

    deinit { refreshTask?.cancel() }

    private var isFresh: Bool {
        guard let refreshedAt, error == nil else { return false }
        return (0..<15).contains(now().timeIntervalSince(refreshedAt))
    }

    func invalidate() {
        refreshedAt = nil
        guard let refreshTask else { return }
        refreshTask.cancel()
        self.refreshTask = nil
        startRefresh()
    }

    func observeChildren(_ threadIDs: Set<String>) {
        if let observedChildren, observedChildren != threadIDs { invalidate() }
        observedChildren = threadIDs
    }

    private static var activeSince: Int64 { Int64(Date.now.addingTimeInterval(-recentWindow).timeIntervalSince1970) }

    func output(for agentID: String) async throws -> ConversationAgentOutput {
        guard let agent = agents.first(where: { $0.identity == agentID || $0.id == agentID }) else { throw ConversationAgentNavigationError.noConversation }
        let source = clusterHosts().first { $0.id == agent.ownerHostId }
        if let owner = agent.ownerHostId, owner != address.hostID {
            guard let source else { throw ConversationAgentNavigationError.hostUnavailable }
            return try await source.gateway.agentOutput(threadID: agent.ownerThreadId, agentID: agent.id)
        }
        return try await gateway.agentOutput(threadID: agent.ownerThreadId, agentID: agent.id)
    }

    func refreshIfNeeded() async {
        guard !isFresh else { return }
        await refresh()
    }

    func refresh() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { continuation in
                guard waiters.count < 32 else { continuation.resume(); return }
                waiters[waiterID] = continuation
                startRefresh()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID) }
        }
    }

    private func startRefresh() {
        guard refreshTask == nil else { return }
        let id = UUID()
        refreshID = id
        if !isRefreshing { isRefreshing = true }
        var hosts = clusterHosts()
        if !hosts.contains(where: { $0.id == address.hostID }) {
            hosts.append(.init(id: address.hostID, name: "Gateway", gateway: gateway, supportsCrossHost: false))
        }
        let parent = ClusterParent(hostId: address.hostID, threadId: threadID)
        let previous = Dictionary(coverage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        coverage = hosts.map { previous[$0.id] ?? .init(hostId: $0.id, name: $0.name, state: .unknown) }
        let configured = Set(coverage.map(\.id))
        coverage += knownCoverage().filter { !configured.contains($0.id) }
        refreshTask = Task { [weak self] in
            await withTaskGroup(of: (ConversationAgentsHost, Result<ConversationAgentsPage, Error>).self) { group in
                for host in hosts {
                    group.addTask {
                        do {
                            guard host.id == parent.hostId || host.supportsCrossHost else { throw ClusterReadFailure.unsupported }
                            let page = try await host.gateway.conversationAgents(parent: parent, crossHost: host.supportsCrossHost)
                            return (host, .success(page))
                        } catch { return (host, .failure(error)) }
                    }
                }
                for await (host, result) in group {
                    guard let self, self.refreshID == id, !Task.isCancelled else { continue }
                    self.receive(result, from: host, id: id)
                }
            }
            self?.finish(id: id)
        }
    }

    private func receive(_ result: Result<ConversationAgentsPage, Error>, from host: ConversationAgentsHost, id: UUID) {
        guard refreshID == id else { return }
        let previous = coverage.first { $0.id == host.id }
        let item: ClusterCoverage
        switch result {
        case .success(let page):
            rowsByHost[host.id] = page.agents.map { agent in
                var row = agent
                row.ownerHostId = row.ownerHostId ?? host.id
                row.hostName = row.hostName ?? (row.ownerHostId == host.id ? host.name : nil)
                return row
            }
            warningsByHost[host.id] = page.warnings
            error = nil
            hasLoaded = true
            refreshedAt = now()
            successfulReads[host.id] = now()
            item = .init(hostId: host.id, name: host.name, state: .ok)
        case .failure(let failure):
            if failure is CancellationError { return }
            let unsupported: Bool
            if failure is ClusterReadFailure { unsupported = true }
            else if case GatewayClient.ClientError.serverError(_, let code) = failure, code == -32601 { unsupported = true }
            else { unsupported = false }
            let transportFailure: Bool
            if failure is URLError { transportFailure = true }
            else if let client = failure as? GatewayClient.ClientError {
                switch client {
                case .notConnected, .connectionClosed, .connectionFailed, .gatewayRestarting, .gatewayNotReady, .requestTimedOut:
                    transportFailure = true
                default: transportFailure = false
                }
            } else { transportFailure = false }
            let state: ClusterCoverage.State = unsupported ? .unsupported : transportFailure ? .unreachable : .stale
            item = .init(hostId: host.id, name: host.name, state: state,
                         since: state == .unreachable ? previous?.since ?? ISO8601DateFormatter().string(from: now()) : nil,
                         staleThrough: successfulReads[host.id].map { ISO8601DateFormatter().string(from: $0) })
            if host.id == address.hostID { error = failure.localizedDescription }
        }
        coverage = coverage.map { $0.id == host.id ? item : $0 }
        for row in rowsByHost[host.id] ?? [] {
            if let owner = row.ownerHostId, !coverage.contains(where: { $0.id == owner }) {
                coverage.append(.init(hostId: owner, name: row.hostName, state: .unknown))
            }
        }
        let hosts = Set(coverage.map(\.id))
        rowsByHost = rowsByHost.filter { hosts.contains($0.key) }
        successfulReads = successfulReads.filter { hosts.contains($0.key) }
        warningsByHost = warningsByHost.filter { hosts.contains($0.key) }
        warnings = Array(Set(warningsByHost.values.flatMap { $0 })).sorted()
        let coverageByHost = Dictionary(coverage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = coverage.flatMap { rowsByHost[$0.id] ?? [] }.map { row in
            var row = row
            if let owner = row.ownerHostId, let coverage = coverageByHost[owner] {
                row.hostName = coverage.name
                row.reachability = coverage.state == .ok ? "reachable" : coverage.state.rawValue
            }
            return row
        }
        let unavailableIntents = Set(rows.filter {
            $0.isStub == true && ($0.intentState == "unknown" || $0.intentState == "removed") && $0.reachability != "reachable"
        }.map(\.identity))
        agents = ConversationAgentsProjection.merge(rows.filter { $0.isStub == true || !unavailableIntents.contains($0.identity) })
        sections = ConversationAgentSections(agents: agents, activeSince: Self.activeSince)
    }

    private enum ClusterReadFailure: Error { case unsupported }

    private func finish(id: UUID) {
        guard refreshID == id else { return }
        refreshTask = nil
        refreshID = nil
        isRefreshing = false
        let completed = waiters.values
        waiters.removeAll()
        for waiter in completed { waiter.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume()
        guard waiters.isEmpty else { return }
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        isRefreshing = false
    }
}
