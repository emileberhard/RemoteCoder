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
    private(set) var coverageByHost: [UUID: ClusterCoverage] = [:]
    @ObservationIgnored private var agentsByID: [String: ConversationAgent] = [:]
    @ObservationIgnored var clusterHosts: @MainActor () -> [ConversationAgentsHost] = { [] }
    @ObservationIgnored var knownCoverage: @MainActor () -> [ClusterCoverage] = { [] }
    @ObservationIgnored private var rowsByHost: [UUID: [ConversationAgent]] = [:]
    @ObservationIgnored private var warningsByHost: [UUID: [String]] = [:]
    @ObservationIgnored private var pendingCoverage: [UUID: ClusterCoverage] = [:]
    @ObservationIgnored private var hostOrder: [UUID] = []
    @ObservationIgnored private var successfulReads: [UUID: Date] = [:]
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var projectionID: UUID?
    @ObservationIgnored private var projectionVersion = 0
    @ObservationIgnored private var projectionDirty = false
    @ObservationIgnored private var lastPublication: ContinuousClock.Instant?
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

    deinit { refreshTask?.cancel(); projectionTask?.cancel() }

    private var isFresh: Bool {
        guard let refreshedAt, error == nil else { return false }
        return (0..<15).contains(now().timeIntervalSince(refreshedAt))
    }

    func agent(for id: String) -> ConversationAgent? { agentsByID[id] }

    func invalidate() {
        refreshedAt = nil
        guard let refreshTask else { return }
        refreshTask.cancel()
        self.refreshTask = nil
        projectionTask?.cancel()
        projectionTask = nil
        startRefresh()
    }

    func observeChildren(_ threadIDs: Set<String>) {
        if let observedChildren, observedChildren != threadIDs { invalidate() }
        observedChildren = threadIDs
    }

    func output(for agentID: String) async throws -> ConversationAgentOutput {
        guard let agent = agentsByID[agentID] else { throw ConversationAgentNavigationError.noConversation }
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
        isRefreshing = true
        var hosts = clusterHosts()
        if let index = hosts.firstIndex(where: { $0.id == address.hostID }) { hosts.swapAt(0, index) }
        else { hosts.insert(.init(id: address.hostID, name: "Gateway", gateway: gateway, supportsCrossHost: false), at: 0) }
        hostOrder = []
        pendingCoverage = [:]
        for host in hosts {
            hostOrder.append(host.id)
            pendingCoverage[host.id] = coverageByHost[host.id] ?? .init(hostId: host.id, name: host.name, state: .unknown)
        }
        for item in knownCoverage() where pendingCoverage[item.id] == nil {
            hostOrder.append(item.id)
            pendingCoverage[item.id] = item
        }
        rowsByHost = rowsByHost.filter { pendingCoverage[$0.key] != nil }
        warningsByHost = warningsByHost.filter { pendingCoverage[$0.key] != nil }
        successfulReads = successfulReads.filter { pendingCoverage[$0.key] != nil }
        let parent = ClusterParent(hostId: address.hostID, threadId: threadID)
        refreshTask = Task { [weak self] in
            var answered: Set<UUID> = []
            await BoundedFanOut.run(hosts, limit: BoundedFanOut.hostLimit, deadline: .now + .seconds(10), skipping: { _ in false }) { host in
                let result: Result<ConversationAgentsPage, Error>
                do {
                    guard host.id == parent.hostId || host.supportsCrossHost else { throw ClusterReadFailure.unsupported }
                    result = .success(try await host.read(parent: parent))
                } catch { result = .failure(error) }
                guard let self, self.refreshID == id, !Task.isCancelled else { return }
                answered.insert(host.id)
                self.receive(result, from: host, id: id)
            }
            guard let self, self.refreshID == id, !Task.isCancelled else { return }
            for host in hosts where !answered.contains(host.id) { self.receive(.failure(ClusterReadFailure.deadline), from: host, id: id) }
            await self.projectionTask?.value
            self.finish(id: id)
        }
    }

    private func receive(_ result: Result<ConversationAgentsPage, Error>, from host: ConversationAgentsHost, id: UUID) {
        guard refreshID == id else { return }
        switch result {
        case .success(let page):
            rowsByHost[host.id] = page.agents
            warningsByHost[host.id] = page.warnings
            if host.id == address.hostID { error = nil }
            refreshedAt = now()
            successfulReads[host.id] = now()
            pendingCoverage[host.id] = .init(hostId: host.id, name: host.name, state: .ok)
        case .failure(let failure):
            if failure is CancellationError { return }
            let state = ClusterCoverage.State.failure(failure)
            pendingCoverage[host.id] = .init(hostId: host.id, name: host.name, state: state,
                since: state == .unreachable ? pendingCoverage[host.id]?.since ?? now() : nil, staleThrough: successfulReads[host.id])
            if host.id == address.hostID { error = failure.localizedDescription }
        }
        projectionVersion += 1
        projectionDirty = true
        scheduleProjection(refresh: id)
    }

    private func scheduleProjection(refresh: UUID) {
        guard projectionTask == nil else { return }
        let id = UUID()
        projectionID = id
        projectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.projectionID == id { self.projectionTask = nil } }
            while self.projectionDirty, self.refreshID == refresh, !Task.isCancelled {
                do {
                    if let last = self.lastPublication { try await Task.sleep(until: last + .milliseconds(80), clock: .continuous) }
                    self.projectionDirty = false
                    let version = self.projectionVersion
                    let prepared = try await ConversationAgentsProjection.prepare(rowsByHost: self.rowsByHost, warningsByHost: self.warningsByHost,
                        coverage: self.pendingCoverage, hostOrder: self.hostOrder,
                        activeSince: Int64(self.now().addingTimeInterval(-Self.recentWindow).timeIntervalSince1970))
                    guard self.refreshID == refresh, !Task.isCancelled else { return }
                    guard self.projectionVersion == version else { self.projectionDirty = true; continue }
                    self.agents = prepared.agents
                    self.sections = prepared.sections
                    self.warnings = prepared.warnings
                    self.coverage = prepared.coverage
                    self.coverageByHost = prepared.coverageByHost
                    self.agentsByID = prepared.agentsByID
                    self.hasLoaded = self.hasLoaded || !self.successfulReads.isEmpty
                    self.lastPublication = .now
                } catch { return }
            }
        }
    }

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
        projectionTask?.cancel()
        projectionTask = nil
        refreshID = nil
        isRefreshing = false
    }
}
