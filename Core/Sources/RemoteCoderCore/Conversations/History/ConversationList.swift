import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class ConversationList {
    private enum RefreshIntent { case mergeRecent, replaceCoverage }

    private struct PendingRefreshRequest {
        let limit: Int
        let reason: String
        let intent: RefreshIntent
    }

    private enum RefreshPolicy {
        static let incrementalLimit = 30
        static let manualLimit = 200
    }

    private(set) var threads: [ConversationHeader] = []
    private(set) var continuation = ConversationListContinuation()
    private(set) var hasDiscardedHeaders = false
    private(set) var isLoadingOlder = false
    var isLoading = false
    var errorMessage: String?
    private(set) var marksReplica = ConversationMarksReplica()
    private(set) var projects: [String: ProjectIdentity] = [:]
    private(set) var settlementEdits: [String: Int] = [:]

    var marks: ConversationMarks { marksReplica.effective }
    var needsReconnectRefresh: Bool { errorMessage != nil || refreshDeferred }

    @ObservationIgnored var lastSuccessfulRefreshAt: Date?
    @ObservationIgnored private var refreshDeferred = false

    @ObservationIgnored private var hasLoadedPersistedThreads = false
    @ObservationIgnored private var persistedSnapshotLoadTask: Task<ConversationHeaderStore.Snapshot, Never>?
    @ObservationIgnored private var hasLoadedPersistedMarks = false
    @ObservationIgnored private var marksLoad: Task<ConversationMarksStore.Loaded, Never>?
    @ObservationIgnored private let marksWriter: ConversationMarksWriter
    @ObservationIgnored private var marksSync: Task<Void, Never>?
    @ObservationIgnored private var acceptsMarks = true
    @ObservationIgnored private var marksReadRequested = false
    @ObservationIgnored private var marksFlushRequested = false
    @ObservationIgnored private var persistsMarks = true
    @ObservationIgnored private var isReadingMarks = false
    @ObservationIgnored private var marksReadFailed = false
    @ObservationIgnored private var marksRetry: Task<Void, Never>?
    @ObservationIgnored private var marksSuspended = false
    @ObservationIgnored private var marksSyncFailures = 0
    @ObservationIgnored private var receivedDuringMarksRead: ConversationMarks?
    @ObservationIgnored private var pendingRefreshRequest: PendingRefreshRequest?
    @ObservationIgnored private var activeRefreshRequest: PendingRefreshRequest?
    @ObservationIgnored private var locallyChangedDuringRefresh: Set<String> = []
    @ObservationIgnored private var protectedThreadIDs: Set<String> = []
    @ObservationIgnored private var browsedThreadIDs: Set<String> = []
    @ObservationIgnored private var searchContinuation = ConversationListContinuation()
    @ObservationIgnored private var searchQuery = ""
    @ObservationIgnored private var olderProvider = AgentProvider.codex
    @ObservationIgnored private var searchProvider = AgentProvider.codex
    @ObservationIgnored private var listReadGeneration: UInt64 = 0
    @ObservationIgnored private var headerRevision: UInt64 = 0
    @ObservationIgnored private var projectReadGeneration: UInt64 = 0
    @ObservationIgnored private var headerReadsRetired = false
    private enum HeaderRecovery: Equatable {
        case idle
        case reading(String)
        case superseded
    }
    @ObservationIgnored private var headerRecovery = HeaderRecovery.idle
    private struct HeaderRecoveryFailure {
        let retryAt: Date
        let interval: TimeInterval
    }
    @ObservationIgnored private var headerRecoveryFailures: [String: HeaderRecoveryFailure] = [:]
    @ObservationIgnored private let logger = AppLogger(category: "ConversationHistory")
    private let service: GatewayHistoryService
    private let marksRemote: any ConversationMarksRemote
    private let legacyPins: ConversationPinStore
    private let marksStore: any ConversationMarksPersistence
    private let threadStore: ConversationHeaderStore

    init(
        service: GatewayHistoryService,
        marksRemote: any ConversationMarksRemote,
        hostID: UUID,
        threadStore: ConversationHeaderStore,
        marksStore: any ConversationMarksPersistence,
        defaults: UserDefaults
    ) {
        self.service = service
        self.marksRemote = marksRemote
        self.legacyPins = ConversationPinStore.scoped(hostID: hostID, defaults: defaults)
        self.marksStore = marksStore
        self.marksWriter = ConversationMarksWriter(store: marksStore)
        self.threadStore = threadStore
    }

    func bootstrap() async {
        logger.info("bootstrap start")
        await loadPersistedThreadsIfNeeded()
        guard !headerReadsRetired else { return }
        await recoverProtectedHeaders(now: .now)
        guard !headerReadsRetired else { return }
        await refreshIfStale()
    }

    func refresh(reason: String = "incremental") async {
        await loadPersistedThreadsIfNeeded()
        await refresh(limit: RefreshPolicy.incrementalLimit, reason: reason, intent: .mergeRecent)
    }

    private static let staleAutoReason = "stale-auto"

    func refreshIfStale() async {
        await loadPersistedThreadsIfNeeded()
        guard !Task.isCancelled else { return }
        guard shouldRefreshForStaleness() else { return }
        await refresh(limit: RefreshPolicy.incrementalLimit, reason: Self.staleAutoReason, intent: .mergeRecent)
    }

    /// Called after an automatic attempt. Manual refreshes may move the next
    /// deadline later; they never need a one-second readiness poll.
    func automaticRefreshDelay(now: Date = .now) -> Duration {
        HistoryRefreshTiming.delay(after: lastSuccessfulRefreshAt, now: now)
    }

    func record(_ recorded: ConversationHeader) async {
        await loadPersistedThreadsIfNeeded()
        guard !headerReadsRetired else { return }
        noteHeaderMutation(recorded.id)
        var header = recorded
        let previous = threads.first { $0.id == recorded.id }
        header.lastTurnCompletedAt = header.lastTurnCompletedAt
            ?? previous?.lastTurnCompletedAt
        header.pendingHistorySince = previous == nil || previous?.pendingHistorySince != nil ? .now : nil
        let merged = ConversationHeaderStore.merging(current: threads, fetched: [header])
        applyRetained(merged, promoting: [recorded.id])
        if self.header(id: recorded.id) != nil { headerRecoveryFailures.removeValue(forKey: recorded.id) }
        await threadStore.save(snapshot: nextHeaderSnapshot())
    }

    func recordTurnCompletion(threadID: String, completedAt: Int64) async {
        await loadPersistedThreadsIfNeeded()
        guard !headerReadsRetired else { return }
        guard let index = threads.firstIndex(where: { $0.id == threadID }),
              completedAt > (threads[index].lastTurnCompletedAt ?? Int64.min)
        else { return }
        noteHeaderMutation(threadID)
        threads[index].lastTurnCompletedAt = completedAt
        await threadStore.save(snapshot: nextHeaderSnapshot())
    }

    func recordThreadName(threadID: String, name: String?) async {
        await loadPersistedThreadsIfNeeded()
        guard !headerReadsRetired else { return }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = name?.isEmpty == false ? name : nil
        guard let index = threads.firstIndex(where: { $0.id == threadID }),
              threads[index].name != normalized
        else { return }
        noteHeaderMutation(threadID)
        threads[index].name = normalized
        applyRetained(threads, promoting: [threadID])
        await threadStore.save(snapshot: nextHeaderSnapshot())
    }

    func forget(_ threadID: String) async {
        await loadPersistedThreadsIfNeeded()
        guard !headerReadsRetired else { return }
        noteHeaderMutation(threadID)
        applyRetained(threads.filter { $0.id != threadID }, promoting: [])
        settlementEdits.removeValue(forKey: threadID)
        await threadStore.save(snapshot: nextHeaderSnapshot())
    }

    func manualRefresh(reason: String = "manual-refresh") async {
        headerRecoveryFailures.removeAll()
        await loadPersistedThreadsIfNeeded()
        await refresh(limit: RefreshPolicy.manualLimit, reason: reason, intent: .replaceCoverage)
    }

    func pinnedName(for threadID: String) -> String? {
        marks.pinName(for: threadID)
    }

    func pin(threadID: String, name: String) {
        guard let name = ConversationPinName.normalized(name) else { return }
        recordMark(.pin(threadID: threadID, name: name))
    }

    func unpin(threadID: String) {
        recordMark(.unpin(threadID: threadID))
    }

    func markSeen(threadID: String, completedAt: Int64) {
        recordMark(.markRead(threadID: threadID, through: completedAt))
    }

    func markRead(threadIDs: [String]) {
        let completion = Dictionary(threads.map { ($0.id, $0.lastTurnCompletedAt) }, uniquingKeysWith: { first, _ in first })
        for threadID in threadIDs {
            recordMark(.markRead(threadID: threadID, through: (completion[threadID] ?? nil) ?? 0))
        }
    }

    func markUnread(threadID: String) {
        recordMark(.markUnread(threadID: threadID))
    }

    func markAllRead() {
        recordMark(.markAllRead(through: Int64(Date().timeIntervalSince1970)))
    }

    func header(id: String) -> ConversationHeader? {
        threads.first { $0.id == id }
    }

    func settle(threadIDs: [String], newestRequestAt: [String: Int64]) -> [ConversationSettlementEdit] {
        let settling = marks.settling(threadIDs.compactMap { header(id: $0) }, newestRequestAt: newestRequestAt)
        for edit in settling.edits { recordSettlement(edit) }
        return settling.undo
    }

    func unsettle(threadIDs: [String]) {
        for edit in marks.unsettling(threadIDs.compactMap { header(id: $0) }) { recordSettlement(edit) }
    }

    func undoSettle(_ undo: [ConversationSettlementEdit]) {
        guard marks.offersSettlement else { return }
        for edit in undo { recordSettlement(edit) }
    }

    private func recordSettlement(_ edit: ConversationSettlementEdit) {
        guard acceptsMarks else { return }
        for change in edit.changes { recordMark(change) }
        settlementEdits[edit.threadID, default: 0] += 1
    }

    func receiveMarks(_ delta: ConversationMarks) {
        if isReadingMarks {
            if receivedDuringMarksRead == nil { receivedDuringMarksRead = delta }
            else { receivedDuringMarksRead?.apply(delta) }
        }
        marksReplica.receive(delta)
        persistMarks()
    }

    var marksNeedSync: Bool { marksReadFailed || !marksReplica.pending.isEmpty }

    func syncMarks() async {
        guard acceptsMarks else { return }
        marksSuspended = false
        marksSyncFailures = 0
        marksReadRequested = true
        await startMarksSync().value
        guard acceptsMarks, !marksSuspended else { return }
        await recoverProtectedHeaders(now: .now)
    }

    func quiesce() {
        acceptsMarks = false
        marksRetry?.cancel()
        marksRetry = nil
    }

    func suspendMarksSync() {
        marksSuspended = true
        marksRetry?.cancel()
        marksRetry = nil
    }

    func drain() async {
        await marksSync?.value
    }

    func resume() {
        precondition(marksSync == nil)
        acceptsMarks = true
    }

    @discardableResult
    func flushMarks() async -> Bool {
        await loadPersistedMarksIfNeeded()
        guard persistsMarks else { return false }
        return await marksWriter.flush()
    }

    private func recordMark(_ change: ConversationMarkChange) {
        guard acceptsMarks else { return }
        let before = marks
        if marksReplica.isReadStateKnown, before.applying(change) == before { return }
        marksReplica.record(change)
        persistMarks()
        marksFlushRequested = true
        _ = startMarksSync()
    }

    private func startMarksSync() -> Task<Void, Never> {
        if let marksSync { return marksSync }
        let task = Task { await synchronizeMarks() }
        marksSync = task
        return task
    }

    private func synchronizeMarks() async {
        defer { marksSync = nil }
        await loadPersistedMarksIfNeeded()
        repeat {
            guard !marksSuspended else { break }
            let needsRead = marksReadRequested
            marksReadRequested = false
            marksFlushRequested = false
            if needsRead || !marksReplica.isReadStateKnown { await readMarks() }
            if marksReplica.isReadStateKnown { await sendPendingMarks() }
        } while marksReadRequested || marksFlushRequested
        if marksReplica.isReadStateKnown, marksReplica.pending.isEmpty { legacyPins.clear() }
        scheduleMarksRetry()
    }

    private func scheduleMarksRetry() {
        guard marksNeedSync else { marksSyncFailures = 0; return }
        guard acceptsMarks, !marksSuspended, marksRetry == nil, marksSyncFailures < Self.marksSyncAttempts else { return }
        marksSyncFailures += 1
        let delay = Duration.seconds(min(1 << min(marksSyncFailures, 5), 30))
        marksRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, acceptsMarks, !marksSuspended else { return }
            marksRetry = nil
            marksReadRequested = marksReadFailed
            marksFlushRequested = true
            _ = startMarksSync()
        }
    }

    private static let marksSyncAttempts = 8

    private func readMarks() async {
        await loadPersistedThreadsIfNeeded()
        guard !marksSuspended else { return }
        isReadingMarks = true
        receivedDuringMarksRead = nil
        defer { isReadingMarks = false; receivedDuringMarksRead = nil }
        do {
            let remote = try await marksRemote.readConversationMarks()
            marksReplica.replaceAcknowledged(remote)
            if let receivedDuringMarksRead { marksReplica.receive(receivedDuringMarksRead) }
            marksReadFailed = !marksReplica.isReadStateKnown
            persistMarks()
        } catch {
            marksReadFailed = true
            logger.error("conversation marks read failed: \(error.localizedDescription)")
        }
    }

    private func sendPendingMarks() async {
        while !marksSuspended, !marksReplica.pending.isEmpty {
            let batch = Array(marksReplica.pending.prefix(ConversationMarksReplica.batchLimit))
            do {
                let delta = try await marksRemote.updateConversationMarks(batch.map(\.change))
                marksReplica.acknowledge(batch, delta: delta)
                persistMarks()
            } catch {
                logger.notice("conversation marks kept for the next connection: \(error.localizedDescription)")
                return
            }
        }
    }

    private func persistMarks() {
        guard hasLoadedPersistedMarks, persistsMarks else { return }
        marksWriter.replace(marksReplica)
    }

    func resolveProjects() async {
        guard !headerReadsRetired, !Task.isCancelled else { return }
        let missing = Set(threads.lazy.filter { !$0.isDelegatedAgent }.map(\.cwd)).subtracting(projects.keys).sorted()
        guard !missing.isEmpty else { return }
        projectReadGeneration &+= 1
        let generation = projectReadGeneration
        for start in stride(from: 0, to: missing.count, by: 500) {
            let chunk = Array(missing[start..<min(start + 500, missing.count)])
            do {
                let identities = try await marksRemote.resolveProjects(directories: chunk)
                guard !headerReadsRetired, generation == projectReadGeneration, !Task.isCancelled else { return }
                let requested = Set(chunk)
                for identity in identities where requested.contains(identity.cwd) {
                    projects[identity.cwd] = identity
                }
            } catch {
                logger.notice("project identities unavailable: \(error.localizedDescription)")
                return
            }
        }
    }

    private func refresh(limit: Int, reason: String, intent: RefreshIntent) async {
        guard !headerReadsRetired, !Task.isCancelled else { return }
        guard intent == .replaceCoverage || !isLoadingOlder else { return }
        let request = PendingRefreshRequest(limit: limit, reason: reason, intent: intent)
        if let activeRefreshRequest {
            if activeRequestSatisfies(request: request, active: activeRefreshRequest) {
                logger.notice(
                    "refresh ignored; active request already satisfies it (reason=\(reason), limit=\(limit))"
                )
                return
            }
            queuePendingRefresh(request)
            logger.info("refresh queued while loading (reason=\(reason), limit=\(limit))")
            return
        }

        let showsLoading = reason != Self.staleAutoReason || lastSuccessfulRefreshAt == nil
        listReadGeneration &+= 1
        let generation = listReadGeneration
        isLoadingOlder = false
        if showsLoading { isLoading = true }
        locallyChangedDuringRefresh.removeAll()
        activeRefreshRequest = request
        if errorMessage != nil { errorMessage = nil }
        refreshDeferred = false
        logger.info("refresh start (reason=\(reason), limit=\(limit), knownThreads=\(self.threads.count))")

        var persisted: ConversationHeaderStore.Snapshot?
        do {
            let result = try await service.fetchRecentThreads(
                limit: limit,
                useStateDBOnly: limit <= RefreshPolicy.incrementalLimit,
                knownHeaders: threads
            )
            try Task.checkCancellation()
            guard !headerReadsRetired, generation == listReadGeneration else { throw CancellationError() }
            let previousDates = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0.lastTurnCompletedAt) })
            let fetched = result.threads.map { thread in
                var header = thread
                if result.unavailableCompletionTimes.contains(thread.id) {
                    header.lastTurnCompletedAt = previousDates[thread.id] ?? nil
                }
                return header
            }
            let complete = result.failures.isEmpty && !result.isDeferred
            // A local create/remove/completion after this request began is newer evidence.
            let merged = complete ? ConversationHeaderStore.refreshing(
                current: threads, recent: fetched, continuation: result.continuation,
                retaining: priorityThreadIDs, preserving: locallyChangedDuringRefresh
            ) : ConversationHeaderStore.merging(
                current: threads, fetched: fetched.filter { !locallyChangedDuringRefresh.contains($0.id) }
            )
            let retained = await service.classifyRetainedAgents(merged)
            try Task.checkCancellation()
            guard !headerReadsRetired, generation == listReadGeneration else { throw CancellationError() }
            let classified = retained.threads.isEmpty ? merged
                : ConversationHeaderStore.merging(current: merged, fetched: retained.threads)
            let committed = ConversationHeaderStore.merging(
                current: classified.filter { !locallyChangedDuringRefresh.contains($0.id) },
                fetched: threads.filter { locallyChangedDuringRefresh.contains($0.id) }
            )
            let refreshDate = complete ? Date() : lastSuccessfulRefreshAt
            listReadGeneration &+= 1
            let reopensCodex = continuation.codex == .end && result.continuation.codex.canLoad
            let reopensClaude = continuation.claude == .end && result.continuation.claude.canLoad
            let initializesCodex = intent == .replaceCoverage || continuation.codex == .notLoaded || reopensCodex
            let initializesClaude = intent == .replaceCoverage || continuation.claude == .notLoaded || reopensClaude
            if intent == .replaceCoverage {
                searchQuery = ""
                searchContinuation = ConversationListContinuation()
                browsedThreadIDs = []
                olderProvider = .codex
                searchProvider = .codex
            }
            if reopensCodex, searchContinuation.codex == .end { searchContinuation.codex = .notLoaded }
            if reopensClaude, searchContinuation.claude == .end { searchContinuation.claude = .notLoaded }
            if complete, !result.continuation.canLoad { hasDiscardedHeaders = false }
            applyRetained(committed, promoting: intent == .replaceCoverage || browsedThreadIDs.isEmpty ? Set(fetched.map(\.id)) : [])
            let admitted = Set(threads.map(\.id)).union(locallyChangedDuringRefresh)
            if initializesCodex {
                continuation.codex = fetched.filter { !$0.isDelegatedAgent && AgentProvider.provider(forThreadID: $0.id) == .codex }
                    .allSatisfy { admitted.contains($0.id) } ? result.continuation.codex : .notLoaded
            }
            if initializesClaude {
                continuation.claude = fetched.filter { !$0.isDelegatedAgent && AgentProvider.provider(forThreadID: $0.id) == .claude }
                    .allSatisfy { admitted.contains($0.id) } ? result.continuation.claude : .notLoaded
            }
            lastSuccessfulRefreshAt = refreshDate
            refreshDeferred = result.isDeferred
            let failure = result.failures.isEmpty ? nil : result.failures.joined(separator: "\n")
            if errorMessage != failure { errorMessage = failure }
            for warning in Set(result.agentWarnings + retained.warnings) {
                logger.notice("Agent coverage: \(warning)")
            }
            logger.info("refresh success (reason=\(reason), requested=\(limit), fetched=\(result.threads.count), merged=\(merged.count))")
            persisted = nextHeaderSnapshot()
        } catch is CancellationError {
            // SwiftUI cancels refresh tasks opportunistically (e.g. gesture conflicts).
            // Treat cancellations as a no-op rather than surfacing them as user-facing errors.
            logger.info("refresh cancelled (reason=\(reason), limit=\(limit))")
        } catch where GatewayHistoryService.defersRead(error) {
            refreshDeferred = true
            logger.notice("refresh deferred until the gateway and Codex are ready (reason=\(reason))")
        } catch {
            guard !headerReadsRetired else { return }
            errorMessage = error.localizedDescription
            logger.error("refresh failed (reason=\(reason), limit=\(limit)): \(error.localizedDescription)")
        }
        if showsLoading { isLoading = false }
        activeRefreshRequest = nil
        if let persisted {
            await threadStore.save(snapshot: persisted)
            await resolveProjects()
            await recoverProtectedHeaders(now: .now)
        }

        if let pending = pendingRefreshRequest {
            pendingRefreshRequest = nil
            logger.info("running queued refresh (reason=\(pending.reason), limit=\(pending.limit))")
            await refresh(limit: pending.limit, reason: pending.reason, intent: pending.intent)
        }
    }

    private func loadPersistedMarksIfNeeded() async {
        guard !hasLoadedPersistedMarks else { return }
        if marksLoad == nil {
            let marksStore = self.marksStore
            marksLoad = Task { await marksStore.load() }
        }
        guard let marksLoad else { return }
        let loaded = await marksLoad.value
        self.marksLoad = nil
        guard !hasLoadedPersistedMarks else { return }
        switch loaded {
        case let .stored(replica):
            marksReplica.restore(replica)
        case .missing:
            var legacy = ConversationMarksReplica()
            for (threadID, name) in legacyPins.load().sorted(by: { $0.key < $1.key }) {
                guard let name = ConversationPinName.normalized(name) else { continue }
                legacy.record(.pin(threadID: threadID, name: name))
            }
            legacy.retireDefaultScope()
            marksReplica.restore(legacy)
        case .unavailable:
            persistsMarks = false
        }
        hasLoadedPersistedMarks = true
        persistMarks()
    }

    private func loadPersistedThreadsIfNeeded() async {
        if headerReadsRetired || hasLoadedPersistedThreads { return }
        await loadPersistedMarksIfNeeded()
        guard !headerReadsRetired, !hasLoadedPersistedThreads else { return }
        if persistedSnapshotLoadTask == nil {
            let threadStore = self.threadStore
            persistedSnapshotLoadTask = Task { await threadStore.load() }
        }
        guard let persistedSnapshotLoadTask else { return }
        let snapshot = await persistedSnapshotLoadTask.value
        self.persistedSnapshotLoadTask = nil
        if headerReadsRetired || hasLoadedPersistedThreads { return }

        hasDiscardedHeaders = snapshot.hasDiscardedHeaders
        headerRevision = snapshot.revision
        applyWindow(ConversationHeaderStore.merging(current: [], fetched: snapshot.threads), promoting: [])
        lastSuccessfulRefreshAt = snapshot.lastSuccessfulRefreshAt
        hasLoadedPersistedThreads = true
        logger.info("loaded persisted threads (count=\(self.threads.count), hasLastRefresh=\(self.lastSuccessfulRefreshAt != nil))")
    }

    func knownThread(id: String) async -> ConversationHeader? {
        await loadPersistedThreadsIfNeeded()
        return headerReadsRetired ? nil : header(id: id)
    }

    func finishHeaderRetirement() async {
        await threadStore.retire()
    }

    func retireHeaderReads() {
        headerReadsRetired = true
        listReadGeneration &+= 1
        headerRecovery = .superseded
        pendingRefreshRequest = nil
        persistedSnapshotLoadTask?.cancel()
        isLoading = false
        isLoadingOlder = false
    }

    func setProtectedThreadIDs(_ ids: Set<String>) -> Bool {
        guard protectedThreadIDs != ids else { return false }
        protectedThreadIDs = ids
        return true
    }

    var unloadedPinnedThreads: [String: String] {
        let loaded = Set(threads.map(\.id))
        return marks.threads.reduce(into: [:]) { result, entry in
            if !loaded.contains(entry.key), let name = entry.value.pinName { result[entry.key] = name }
        }
    }

    func canLoadOlder(query: String) -> Bool {
        guard !headerReadsRetired else { return false }
        let query = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return query.isEmpty ? continuation.canLoad : query != searchQuery || searchContinuation.canLoad
    }

    func loadOlder(query: String, including matches: (ConversationHeader) -> Bool) async {
        await loadPersistedThreadsIfNeeded()
        guard !headerReadsRetired, activeRefreshRequest == nil, !Task.isCancelled else { return }
        let query = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !query.isEmpty, query != searchQuery {
            searchQuery = query
            searchContinuation = ConversationListContinuation()
            searchProvider = .codex
            listReadGeneration &+= 1
            isLoadingOlder = false
        }
        guard !isLoadingOlder, canLoadOlder(query: query) else { return }
        let positions = query.isEmpty ? continuation : searchContinuation
        let preferred = query.isEmpty ? olderProvider : searchProvider
        let provider: AgentProvider = if preferred == .codex { positions.codex.canLoad ? .codex : .claude }
            else { positions.claude.canLoad ? .claude : .codex }
        let position = provider == .codex ? positions.codex : positions.claude
        listReadGeneration &+= 1
        let generation = listReadGeneration
        locallyChangedDuringRefresh.removeAll()
        isLoadingOlder = true
        defer { if generation == listReadGeneration { isLoadingOlder = false } }
        do {
            let result = try await service.fetchOlderPage(provider: provider, position: position, knownHeaders: threads)
            try Task.checkCancellation()
            guard !headerReadsRetired, generation == listReadGeneration else { return }
            let fetched = (query.isEmpty ? result.threads : result.threads.filter(matches))
                .filter { !locallyChangedDuringRefresh.contains($0.id) }
            let previousDates = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0.lastTurnCompletedAt) })
            let headers = fetched.map { thread in
                var header = thread
                if result.unavailable.contains(thread.id) { header.lastTurnCompletedAt = previousDates[thread.id] ?? nil }
                return header
            }
            if !headers.isEmpty { browsedThreadIDs = Set(headers.map(\.id)) }
            applyRetained(ConversationHeaderStore.merging(current: threads, fetched: headers), promoting: [])
            var advanced = positions
            if provider == .codex { advanced.codex = result.position } else { advanced.claude = result.position }
            let next: AgentProvider = provider == .codex ? .claude : .codex
            if query.isEmpty { continuation = advanced; olderProvider = next }
            else { searchContinuation = advanced; searchProvider = next }
            errorMessage = result.unavailable.isEmpty ? nil : "Some completion times couldn't be loaded; keeping their last known values."
            for warning in result.warnings { logger.notice("Agent coverage: \(warning)") }
            await threadStore.save(snapshot: nextHeaderSnapshot())
            guard !headerReadsRetired, generation == listReadGeneration, !Task.isCancelled else { return }
            await resolveProjects()
        } catch is CancellationError {
        } catch {
            guard generation == listReadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func recoverProtectedHeaders(now: Date) async {
        await loadPersistedThreadsIfNeeded()
        guard !headerReadsRetired, headerRecovery == .idle else { return }
        defer { headerRecovery = .idle }
        let priority = priorityThreadIDs
        headerRecoveryFailures = headerRecoveryFailures.filter { priority.contains($0.key) }
        var attempted = Set<String>()
        for _ in 0..<32 {
            guard !headerReadsRetired, !Task.isCancelled else { return }
            let pending = priorityThreadIDs.subtracting(threads.map(\.id)).subtracting(attempted)
                .filter { (headerRecoveryFailures[$0]?.retryAt ?? .distantPast) <= now }
            guard let id = pending.intersection(protectedThreadIDs).min() ?? pending.min() else { break }
            attempted.insert(id)
            headerRecovery = .reading(id)
            do {
                let header = try await service.readHeader(threadID: id)
                try Task.checkCancellation()
                guard headerRecovery == .reading(id), self.header(id: id) == nil else { continue }
                guard header.id == id else { throw GatewayClient.ClientError.invalidMessage }
                guard priorityThreadIDs.contains(id) else { continue }
                let classified = await service.classifyAgents([header])
                try Task.checkCancellation()
                guard headerRecovery == .reading(id), self.header(id: id) == nil else { continue }
                guard priorityThreadIDs.contains(id), let header = classified.threads.first else { continue }
                if activeRefreshRequest != nil || isLoadingOlder { locallyChangedDuringRefresh.insert(id) }
                applyRetained(ConversationHeaderStore.merging(current: threads, fetched: [header]), promoting: [])
                await threadStore.save(snapshot: nextHeaderSnapshot())
                try Task.checkCancellation()
                if self.header(id: id) != nil { headerRecoveryFailures.removeValue(forKey: id) }
                else { recordRecoveryFailure(id, now: now) }
            } catch is CancellationError { return }
            catch {
                guard headerRecovery == .reading(id), self.header(id: id) == nil, priorityThreadIDs.contains(id) else { continue }
                recordRecoveryFailure(id, now: now)
                errorMessage = "Some pinned or active conversations couldn't be loaded. Try again when the host is available."
            }
        }
    }

    private func noteHeaderMutation(_ id: String) {
        if activeRefreshRequest != nil || isLoadingOlder { locallyChangedDuringRefresh.insert(id) }
        if headerRecovery == .reading(id) { headerRecovery = .superseded }
    }

    private func nextHeaderSnapshot() -> ConversationHeaderStore.Snapshot {
        headerRevision += 1
        return .init(threads: threads, lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
                     hasDiscardedHeaders: hasDiscardedHeaders, revision: headerRevision)
    }

    private func recordRecoveryFailure(_ id: String, now: Date) {
        let interval = min((headerRecoveryFailures[id]?.interval ?? 15) * 2, 600)
        headerRecoveryFailures[id] = HeaderRecoveryFailure(retryAt: now.addingTimeInterval(interval), interval: interval)
        if headerRecoveryFailures.count > ConversationHeaderRetention.countLimit,
           let oldest = headerRecoveryFailures.min(by: { $0.value.retryAt < $1.value.retryAt }) {
            headerRecoveryFailures.removeValue(forKey: oldest.key)
        }
    }

    private var pinnedThreadIDs: Set<String> {
        Set(marks.threads.compactMap { $0.value.pinName != nil ? $0.key : nil })
    }

    private var priorityThreadIDs: Set<String> { protectedThreadIDs.union(pinnedThreadIDs) }

    private func applyRetained(_ headers: [ConversationHeader], promoting ids: Set<String>) {
        applyWindow(headers.filter { !$0.isDelegatedAgent || protectedThreadIDs.contains($0.id) }, promoting: ids)
    }

    private func applyWindow(_ headers: [ConversationHeader], promoting ids: Set<String>) {
        let promoted = browsedThreadIDs.union(ids)
        let retained = ConversationHeaderRetention.retain(headers, prioritizing: protectedThreadIDs,
                                                          pinned: pinnedThreadIDs, promoting: promoted)
        if case let .reading(id) = headerRecovery, retained.threads.contains(where: { $0.id == id }) {
            headerRecovery = .superseded
        }
        let retainedIDs = Set(retained.threads.map(\.id))
        if !searchQuery.isEmpty, !searchContinuation.canLoad,
           !browsedThreadIDs.isSubset(of: retainedIDs) {
            searchContinuation = ConversationListContinuation()
        }
        browsedThreadIDs.formIntersection(retainedIDs)
        hasDiscardedHeaders = hasDiscardedHeaders || retained.discarded
        let directories = Set(retained.threads.map(\.cwd))
        if directories != Set(threads.map(\.cwd)) { projectReadGeneration &+= 1 }
        if threads != retained.threads { threads = retained.threads }
        let retainedProjects = projects.filter { directories.contains($0.key) }
        if projects != retainedProjects { projects = retainedProjects }
    }

    private func shouldRefreshForStaleness() -> Bool {
        guard let lastSuccessfulRefreshAt else { return true }
        return Date().timeIntervalSince(lastSuccessfulRefreshAt) >= HistoryRefreshTiming.maximumStaleness
    }

    private func queuePendingRefresh(_ request: PendingRefreshRequest) {
        guard let existing = pendingRefreshRequest else {
            pendingRefreshRequest = request
            return
        }
        pendingRefreshRequest = PendingRefreshRequest(
            limit: max(existing.limit, request.limit),
            reason: request.reason,
            intent: existing.intent == .replaceCoverage || request.intent == .replaceCoverage ? .replaceCoverage : .mergeRecent
        )
    }

    private func activeRequestSatisfies(request: PendingRefreshRequest, active: PendingRefreshRequest) -> Bool {
        active.limit >= request.limit && (active.intent == .replaceCoverage || request.intent == .mergeRecent)
    }
}

#if RC_PERF_HARNESS
extension ConversationList {
    var performanceReplayRefreshState: (settled: Bool, deferred: Bool, revision: UInt64) {
        (activeRefreshRequest == nil && pendingRefreshRequest == nil && !isLoadingOlder, refreshDeferred, headerRevision)
    }
}
#endif
