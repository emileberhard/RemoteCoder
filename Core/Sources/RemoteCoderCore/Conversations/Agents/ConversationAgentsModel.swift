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
    private var revision: String?
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
        try await gateway.agentOutput(threadID: threadID, agentID: agentID)
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
        refreshTask = Task { [weak self, gateway, threadID] in
            do {
                let page = try await gateway.conversationAgents(threadID: threadID)
                try Task.checkCancellation()
                self?.finish(page: page, id: id)
            } catch {
                self?.finish(error: error, id: id)
            }
        }
    }

    private func finish(page: ConversationAgentsPage, id: UUID) {
        guard refreshID == id else { return }
        if revision != page.revision {
            agents = page.agents
            revision = page.revision
        }
        let sections = ConversationAgentSections(agents: agents, activeSince: Self.activeSince)
        if self.sections != sections { self.sections = sections }
        if warnings != page.warnings { warnings = page.warnings }
        if error != nil { error = nil }
        if !hasLoaded { hasLoaded = true }
        refreshedAt = now()
        finish(id: id)
    }

    private func finish(error: any Error, id: UUID) {
        guard refreshID == id else { return }
        if !(error is CancellationError) { self.error = error.localizedDescription }
        finish(id: id)
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
        refreshID = nil
        isRefreshing = false
    }
}
