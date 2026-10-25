import Foundation
import Observation
import OSLog

@MainActor
protocol HistoryEdgeHost: AnyObject {
    var historyReadTarget: HistoryEdgeReader.Target? { get }
    var endsAtNewerHistoryEdge: Bool { get }
    var canPrefetchOlderHistory: Bool { get }
    var loadedTurnCount: Int { get }
    func hasHistoryEdge(_ kind: HistoryEdge.Kind) -> Bool
    func presentsTranscript(_ identity: String) -> Bool
    func applyConversationSnapshot(_ snapshot: GatewayHistoryService.ConversationSnapshot,
                                   read: ConversationState.HistoryRead, from owner: ConversationSession, source: String) async
    func prepareRenderedMessages() async
    func historyReadFailed(_ message: String)
}

@MainActor
@Observable
final class HistoryEdgeReader {
    struct Target {
        let header: ConversationHeader
        let transcriptIdentity: String
        let conversationID: UUID
    }

    private enum Request: Equatable {
        case page(CodexAppServerV2.SortDirection)
        case reload
        case latest
    }

    private struct Read {
        let request: Request
        let task: Task<Void, Never>
    }

    nonisolated static let turnBatch = 25
    private static let prefetchPageLimit = 8
    private static let prefetchDwell = Duration.seconds(1)

    private(set) var status: [HistoryEdge.Kind: HistoryEdge.Status] = [:]
    @ObservationIgnored private let ownedTasks = OwnedTasks<HistoryEdge.Kind>()
    @ObservationIgnored private var reads: [HistoryEdge.Kind: Read] = [:]
    @ObservationIgnored private var prefetchPagesLeft = 0
    @ObservationIgnored private var transcriptCovered = false
    @ObservationIgnored private var deferredLoads: Set<HistoryEdge.Kind> = []
    @ObservationIgnored private var prefetchResume: Task<Void, Never>?
    @ObservationIgnored private var tailRecovery = HistoryTailRecovery()
    @ObservationIgnored private weak var host: (any HistoryEdgeHost)?
    @ObservationIgnored private let historyService: GatewayHistoryService
    @ObservationIgnored private let conversations: ConversationSessions
    @ObservationIgnored private let networkPolicy: HistoryNetworkPolicy
    @ObservationIgnored private let logger = Logger(subsystem: "RemoteCoder", category: "HistoryEdgeReader")

    init(host: any HistoryEdgeHost, historyService: GatewayHistoryService, conversations: ConversationSessions,
         networkPolicy: HistoryNetworkPolicy) {
        self.host = host
        self.historyService = historyService
        self.conversations = conversations
        self.networkPolicy = networkPolicy
    }

    var isIdle: Bool { reads.isEmpty }
    var allowsPrefetch: Bool { networkPolicy.allowsPrefetch }

    @discardableResult
    func load(_ kind: HistoryEdge.Kind) -> Task<Void, Never>? {
        guard !transcriptCovered else {
            deferredLoads.insert(kind)
            return nil
        }
        let request: Request = switch kind {
        case .older: .page(.desc)
        case .newer: .page(.asc)
        case .reload: .reload
        }
        return read(kind, request: request, priority: .foreground, failure: .failed)
    }

    /// Refresh the canonical tail without inventing a turn-specific reload edge.
    func reloadTail() -> Task<Void, Never>? {
        tailRecovery.request(.reload)
        return read(.newer, request: .reload, priority: .foreground, failure: .failed)
    }

    func retainFailedOpening() {
        tailRecovery.request(.reload)
        status[.newer] = .failed
    }

    func showLatest() {
        guard tailRecovery.pending == .latest || host?.endsAtNewerHistoryEdge == true else { return }
        tailRecovery.request(.latest)
        read(.newer, request: .latest, priority: .foreground, failure: .failed)
    }

    func prefetchEarlier() {
        prefetchPagesLeft = Self.prefetchPageLimit
        continuePrefetch()
    }

    func setTranscriptCovered(_ covered: Bool) {
        transcriptCovered = covered
        prefetchResume?.cancel()
        prefetchResume = nil
        guard !covered else { return }
        let deferred = deferredLoads
        deferredLoads.removeAll()
        for kind in deferred { load(kind) }
        guard prefetchPagesLeft > 0 else { return }
        prefetchResume = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.prefetchDwell)) != nil else { return }
            self?.continuePrefetch()
        }
    }

    private func continuePrefetch() {
        guard !transcriptCovered else { return }
        guard prefetchPagesLeft > 0, allowsPrefetch, !AppEnergyPolicy.current.conservesEnergy,
              let host, host.canPrefetchOlderHistory, host.loadedTurnCount < Self.turnBatch else {
            prefetchPagesLeft = 0
            return
        }
        prefetchPagesLeft -= 1
        read(.older, request: .page(.desc), priority: .prefetch, failure: nil)
    }

    func retryFailed() {
        switch tailRecovery.pending {
        case .latest: showLatest()
        case .reload: _ = reloadTail()
        case nil: break
        }
        for (kind, status) in status where status == .failed {
            if kind == .newer, tailRecovery.pending != nil { continue }
            load(kind)
        }
    }

    @discardableResult
    func cancelReads() -> [Task<Void, Never>] {
        prefetchPagesLeft = 0
        deferredLoads.removeAll()
        prefetchResume?.cancel()
        prefetchResume = nil
        let tasks = reads.values.map(\.task)
        for task in tasks { task.cancel() }
        reads.removeAll()
        status = status.filter { $0.value == .failed }
        return tasks
    }

    func quiesce() {
        ownedTasks.quiesce()
        cancelReads()
    }

    func drain() async { await ownedTasks.drain() }

    func resume() { ownedTasks.resume() }

    func reset() {
        cancelReads()
        status.removeAll()
        tailRecovery.reset()
    }

    @discardableResult
    private func read(_ kind: HistoryEdge.Kind, request: Request, priority: HistoryReadScheduler.Priority,
                      failure: HistoryEdge.Status?) -> Task<Void, Never>? {
        if let running = reads[kind] {
            guard request == .latest || request == .reload, running.request != request else { return running.task }
            running.task.cancel()
            reads[kind] = nil
        }
        guard let target = host?.historyReadTarget else { return nil }
        let thread = target.header
        let identity = target.transcriptIdentity
        let conversationID = target.conversationID
        status[kind] = .loading
        let task = ownedTasks.start(kind) { [weak self] in
            guard let self else { return }
            let operation = priority == .prefetch
                ? nil : AppPerformanceDiagnostics.shared.beginHistory(.paging, threadID: thread.id)
            var outcome: HistoryEdge.Status?
            var failureMessage: String?
            var defersFailure = false
            var loadedTail = false
            do {
                let session = await self.conversations.session(conversationID: conversationID, threadID: thread.id)
                var read = await session.beginHistoryRead()
                let snapshot: GatewayHistoryService.ConversationSnapshot
                switch request {
                case .page(let direction):
                    guard let window = read.base else { throw HistoryReadFailure.notLoaded }
                    snapshot = try await self.historyService.page(header: thread, window: window, direction: direction, priority: priority)
                case .reload:
                    snapshot = try await self.historyService.openTail(header: thread, base: read.base, priority: priority, bypassCache: true)
                case .latest:
                    if let stored = await self.historyService.cachedConversation(header: thread) {
                        await self.host?.applyConversationSnapshot(stored, read: read, from: session, source: "disk")
                        read = await session.beginHistoryRead()
                    }
                    snapshot = try await self.historyService.openTail(header: thread, base: read.base, priority: priority, bypassCache: true)
                }
                try Task.checkCancellation()
                await self.host?.applyConversationSnapshot(snapshot, read: read, from: session, source: "paging")
                if self.host?.presentsTranscript(identity) == true { await self.host?.prepareRenderedMessages() }
                if case .reload = kind, self.host?.hasHistoryEdge(kind) == true { outcome = failure }
                loadedTail = request == .reload || request == .latest
            } catch {
                if !Task.isCancelled, self.host?.presentsTranscript(identity) == true {
                    self.logger.notice("History page failed: \(error.localizedDescription, privacy: .public)")
                    outcome = failure
                    failureMessage = error.localizedDescription
                    defersFailure = GatewayHistoryService.defersRead(error)
                }
            }
            if let operation { AppPerformanceDiagnostics.shared.finishHistory(operationID: operation) }
            guard !Task.isCancelled, self.host?.presentsTranscript(identity) == true else { return }
            self.reads[kind] = nil
            if loadedTail { self.tailRecovery.loaded() }
            guard request == .latest else {
                self.status[kind] = outcome
                if priority == .prefetch, failureMessage == nil { self.continuePrefetch() }
                return
            }
            self.status[kind] = nil
            if let failureMessage, !defersFailure { self.host?.historyReadFailed(failureMessage) }
        }
        reads[kind] = Read(request: request, task: task)
        return task
    }
}
