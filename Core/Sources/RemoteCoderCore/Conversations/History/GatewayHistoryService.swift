import CryptoKit
import Foundation
import OSLog

actor GatewayHistoryService {
    nonisolated struct ReadGenerations: Sendable {
        private static let capacity = 64
        private var entries: [String: UInt64] = [:]
        private var sequence: UInt64 = 0
        private var evictionFloor: UInt64 = 0

        var count: Int { entries.count }

        subscript(threadID: String) -> UInt64 { entries[threadID] ?? evictionFloor }

        mutating func invalidate(_ threadID: String) {
            sequence += 1
            if entries[threadID] == nil, count >= Self.capacity {
                evictionFloor = sequence
                entries.removeAll(keepingCapacity: true)
            }
            entries[threadID] = sequence
        }
    }

    struct ConversationSnapshot: Sendable {
        enum Source: Sendable { case storedTail, cachedPages, gateway }
        let header: ConversationHeader
        let window: HistoryWindow
        let update: HistoryWindow.Update?
        let fetchedAt: Date
        let source: Source
    }

    struct ObservationHistory: Sendable {
        let turns: [CodexAppServerV2.Turn]
        let entries: [CodexAppServerV2.ThreadItemsListResponse.Entry]
        let update: HistoryWindow.Update?
    }

    private typealias ItemsResponse = CodexAppServerV2.ThreadItemsListResponse
    private typealias TurnsResponse = CodexAppServerV2.ThreadTurnsListResponse

    private static let tailItemPageLimit = 50
    private static let itemPageLimit = 100
    private static let turnPageLimit = 100
    private static let metadataPageLimit = 20
    private static let observationEntryLimit = 200
    private static let observationByteLimit = 4 * 1_024 * 1_024

    private let cache: HistoryPageCache
    private let now: @Sendable () -> Date
    private let scheduler = HistoryReadScheduler()
    private var generations = ReadGenerations()
    private var epoch: UInt64 = 0
    private var nextPageLimits: [String: Int] = [:]
    private var oversizedPages: [String: any Error] = [:]
    private var pendingTailCommits: [String: Task<Void, Never>] = [:]
    private static let prefetchCommitDelay = Duration.seconds(2)
    private struct AgentClassification {
        let ancestry: ConversationAgentClassification
        let warnings: [String]
        let updatedAt: Int64
        let checkedAt: Date
        let retryInterval: TimeInterval
        var access: UInt64
        let bytes: Int
    }
    private static let classificationLimit = 4_096
    private static let classificationByteLimit = 4 * 1_024 * 1_024
    private static let unresolvedClassificationRetry: TimeInterval = 30
    private static let maximumClassificationRetry: TimeInterval = 600
    private var agentClassifications: [String: AgentClassification] = [:]
    private var classificationBytes = 0
    private var classificationAccess: UInt64 = 0
    private var retainedClassificationOffset = 0
    private let gateway: any CodexHistoryGateway
    private let logger = AppLogger(category: "CodexGatewayHistory")

    init(gateway: any CodexHistoryGateway, cache: HistoryPageCache = .shared, now: @escaping @Sendable () -> Date = { .now }) {
        self.gateway = gateway
        self.cache = cache
        self.now = now
    }

    func observationCheckpoint(header: ConversationHeader,
        checkpoint: CodexAppServerV2.ThreadObservationCheckpoint,
        previous: HistoryWindow?) async throws -> ObservationHistory {
        let readEpoch = epoch
        let generation = generations[header.id]
        func checkFence() throws {
            try Task.checkCancellation()
            guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
        }
        try checkFence()
        var bytes = 0
        var turns: [CodexAppServerV2.Turn] = []
        var metadata: [HistoryWindow.Update.Metadata] = []
        if let cursor = checkpoint.turnsBackwardsCursor {
            let page: NativePage<TurnsResponse> = try await nativePage(header: header, method: "thread/turns/list",
                cursor: cursor, direction: .desc, priority: .foreground, limit: Self.turnPageLimit, bypassCache: true)
            try checkFence()
            bytes += page.bytes
            guard bytes <= Self.observationByteLimit else { throw ConversationSession.ObservationError.capacity }
            turns = page.value.data.reversed()
            metadata.append(.init(page: Self.measured(HistoryWindow.TurnPage(page.value.data, next: page.value.nextCursor,
                backwards: page.value.backwardsCursor, direction: .desc, placement: .tail, fetchedAt: page.fetchedAt), bytes: page.bytes), placement: .tail))
            try checkFence()
        }
        guard var cursor = checkpoint.itemsBackwardsCursor else {
            return ObservationHistory(turns: turns, entries: [], update: nil)
        }
        let known = Set(previous?.newer == nil ? previous?.items.pages.flatMap { $0.elements.map(\.id) } ?? [] : [])
        let metadataBytes = bytes
        var entries: [ItemsResponse.Entry] = []
        var older: String?
        var fetchedAt: Date?
        while entries.count < Self.observationEntryLimit {
            let page: NativePage<ItemsResponse> = try await nativePage(header: header, method: "thread/items/list",
                cursor: cursor, direction: .desc, priority: .foreground,
                limit: min(Self.tailItemPageLimit, Self.observationEntryLimit - entries.count), bypassCache: true)
            try checkFence()
            bytes += page.bytes
            guard bytes <= Self.observationByteLimit else { throw ConversationSession.ObservationError.capacity }
            entries += page.value.data
            older = page.value.nextCursor
            fetchedAt = fetchedAt ?? page.fetchedAt
            guard let next = page.value.nextCursor, !page.value.data.contains(where: { known.contains($0.id) }) else { break }
            guard next != cursor else { throw GatewayClient.ClientError.invalidMessage }
            cursor = next
        }
        var update = HistoryWindow.Update(
            items: Self.measured(HistoryWindow.ItemPage(elements: entries.reversed(), older: older, newer: nil, fetchedAt: fetchedAt ?? now()), bytes: bytes - metadataBytes),
            placement: .tail, metadata: metadata)
        try checkFence()
        var window = previous ?? HistoryWindow()
        if window.apply(update) {
            try await coverMetadata(&update, window: &window, header: header, priority: .foreground, newer: false)
        }
        try checkFence()
        return ObservationHistory(turns: turns, entries: entries.reversed(), update: update)
    }

    enum RecentRead: Sendable { case full, untilUnchanged }

    private struct RecentCoverage {
        let headers: [ConversationHeader]
        let unavailable: Set<String>
        let hasMore: Bool

        init(headers: [ConversationHeader], unavailable: Set<String>, hasMore: Bool) {
            self.headers = Array(headers.prefix(4_000))
            self.unavailable = unavailable.intersection(self.headers.map(\.id))
            self.hasMore = hasMore || self.headers.count < headers.count
        }

        func matches(_ page: [ConversationHeader], unavailable: Set<String>, offset: Int, hasMore: Bool) -> Bool {
            let end = offset + page.count
            guard end <= headers.count,
                  page.elementsEqual(headers[offset..<end]),
                  unavailable == self.unavailable.intersection(page.map(\.id))
            else { return false }
            return hasMore ? end < headers.count || self.hasMore : end == headers.count && !self.hasMore
        }
    }

    private var recentCoverage: [AgentProvider: RecentCoverage] = [:]
    private var recentReadRevisions: [AgentProvider: UInt64] = [:]

    struct RecentThreads: Sendable {
        let threads: [ConversationHeader]
        let failures: [String]
        let isDeferred: Bool
        let agentWarnings: [String]
        let unavailableCompletionTimes: Set<String>
        let continuation: ConversationListContinuation
        let isUnchanged: Bool
    }

    func fetchRecentThreads(limit: Int, useStateDBOnly: Bool, knownHeaders: [ConversationHeader], read: RecentRead) async throws -> RecentThreads {
        precondition(limit > 0)
        return try await fetchThreads(limit: limit, useStateDBOnly: useStateDBOnly,
            positions: ConversationListContinuation(), pageCountLimit: read == .untilUnchanged ? 21 : 20, knownHeaders: knownHeaders, read: read)
    }

    func fetchOlderPage(provider: AgentProvider, position: ConversationListPosition, knownHeaders: [ConversationHeader]) async throws
        -> (threads: [ConversationHeader], unavailable: Set<String>, warnings: [String], position: ConversationListPosition) {
        let generation = epoch
        let known = Dictionary(knownHeaders.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let page = try await fetchProviderThreads(provider: provider, limit: 200, pageLimit: 200, position: position,
            useStateDBOnly: true, pageCountLimit: 1, known: known, read: .full)
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        return (page.threads, page.unavailable, page.warnings, page.position)
    }

    private func fetchThreads(limit: Int, useStateDBOnly: Bool, positions: ConversationListContinuation,
                              pageCountLimit: Int, knownHeaders: [ConversationHeader], read: RecentRead) async throws -> RecentThreads {
        let generation = epoch
        let known = Dictionary(knownHeaders.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        async let codex = fetchProviderThreads(provider: .codex, limit: limit, pageLimit: min(200, max(50, limit * 2)), position: positions.codex,
            useStateDBOnly: useStateDBOnly, pageCountLimit: pageCountLimit, known: known, read: read)
        async let claude = fetchProviderThreads(provider: .claude, limit: limit, pageLimit: min(200, max(50, limit * 2)), position: positions.claude,
            useStateDBOnly: useStateDBOnly, pageCountLimit: pageCountLimit, known: known, read: read)
        var fetched: [ConversationHeader] = []
        var failures: [String] = []
        var providerErrors: [any Error] = []
        var agentWarnings: [String] = []
        var unavailable = Set<String>()
        var continuation = positions
        var unchangedProviders = 0
        do {
            let result = try await codex
            if result.isUnchanged { unchangedProviders += 1 }
            fetched += result.threads
            unavailable = result.unavailable
            agentWarnings += result.warnings
            continuation.codex = result.position
            if result.coverageIncomplete {
                failures.append("Codex history reached its page limit; retaining cached conversations.")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            providerErrors.append(error)
            if !Self.defersRead(error) { failures.append("Codex history: \(error.localizedDescription)") }
        }
        do {
            let result = try await claude
            if result.isUnchanged { unchangedProviders += 1 }
            fetched += result.threads
            agentWarnings += result.warnings
            continuation.claude = result.position
            if result.coverageIncomplete {
                failures.append("Claude history reached its page limit; retaining cached conversations.")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            providerErrors.append(error)
            if !Self.defersRead(error) { failures.append("Claude history: \(error.localizedDescription)") }
        }
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        if providerErrors.count == 2 {
            if let deferred = providerErrors.first, failures.isEmpty { throw deferred }
            throw HistoryListError.unavailable(failures.joined(separator: "\n"))
        }
        let ordered = ConversationHeaderStore.merging(current: [], fetched: fetched)
        unavailable.formIntersection(ordered.map(\.id))
        if !unavailable.isEmpty {
            failures.append("Completion times unavailable for \(unavailable.count) conversations; retaining their last known order.")
        }
        return RecentThreads(threads: ordered, failures: failures, isDeferred: providerErrors.contains(where: Self.defersRead),
                             agentWarnings: Array(Set(agentWarnings)).sorted(),
                             unavailableCompletionTimes: unavailable, continuation: continuation, isUnchanged: unchangedProviders == 2)
    }

    static func defersRead(_ error: any Error) -> Bool {
        if case GatewayClient.ClientError.gatewayRestarting = error { return true }
        if case .providerUnavailable(.codex, _) = (error as? GatewayRPCFailure)?.kind { return true }
        return false
    }

    func classifyAgents(_ threads: [ConversationHeader]) async -> (threads: [ConversationHeader], warnings: [String]) {
        struct Classification: Decodable, Sendable {
            let relations: [String: ConversationAgentRelation]
            let warnings: [String]
            let knownRoots: [String]?
        }
        var result = threads
        var warnings: [String] = []
        var unresolved: [Int] = []
        let generation = epoch
        for index in result.indices {
            let header = result[index]
            if header.isNativeAgent || header.agentClassification.isDefinitive { continue }
            if var cached = agentClassifications[header.id] {
                if cached.ancestry.isDefinitive
                    || (cached.updatedAt == header.updatedAt && now().timeIntervalSince(cached.checkedAt) < cached.retryInterval) {
                    classificationAccess &+= 1
                    cached.access = classificationAccess
                    agentClassifications[header.id] = cached
                    result[index].agentClassification = cached.ancestry
                    warnings += cached.warnings
                    continue
                }
            }
            unresolved.append(index)
        }
        for offset in stride(from: 0, to: unresolved.count, by: 200) {
            let indexes = unresolved[offset..<min(unresolved.count, offset + 200)]
            do {
                let data = try await gateway.historyPageData(method: "conversation/agents/classify", params: .object([
                    "threadIds": .array(indexes.map { .string(threads[$0].id) })
                ]))
                let page: RPCResult<Classification> = try await Self.decodePage(data)
                try Task.checkCancellation()
                guard generation == epoch else { throw CancellationError() }
                let roots = Set(page.result.knownRoots ?? [])
                for index in indexes {
                    let header = result[index]
                    let ancestry: ConversationAgentClassification
                    if let cached = agentClassifications[header.id], cached.ancestry.isDefinitive {
                        ancestry = cached.ancestry
                    } else if let relation = page.result.relations[header.id] {
                        ancestry = .child(relation)
                    } else if roots.contains(header.id) {
                        ancestry = .root
                    } else {
                        ancestry = .unresolved
                    }
                    result[index].agentClassification = ancestry
                    retainClassification(ancestry, warnings: ancestry.isDefinitive ? [] : page.result.warnings, header: header)
                }
                warnings += page.result.warnings
            } catch {
                let warning = "Agent relationships unavailable; unclassified conversations remain visible."
                if generation == epoch, !Task.isCancelled {
                    for index in indexes where agentClassifications[result[index].id]?.ancestry.isDefinitive != true {
                        retainClassification(.unresolved, warnings: [warning], header: result[index])
                    }
                }
                warnings.append(warning)
                break
            }
        }
        return (result, Array(Set(warnings)).sorted())
    }

    func classifyRetainedAgents(_ threads: [ConversationHeader]) async -> (threads: [ConversationHeader], warnings: [String]) {
        guard !threads.isEmpty else { return ([], []) }
        var pending: [ConversationHeader] = []
        let date = now()
        for _ in threads.indices {
            let index = retainedClassificationOffset % threads.count
            retainedClassificationOffset = (index + 1) % threads.count
            let header = threads[index]
            guard !header.isNativeAgent, !header.agentClassification.isDefinitive else { continue }
            if let cached = agentClassifications[header.id] {
                if !cached.ancestry.isDefinitive && cached.updatedAt == header.updatedAt
                    && date.timeIntervalSince(cached.checkedAt) < cached.retryInterval { continue }
            }
            pending.append(header)
            if pending.count == 200 { break }
        }
        return await classifyAgents(pending)
    }

    private func retainClassification(_ ancestry: ConversationAgentClassification, warnings: [String], header: ConversationHeader) {
        classificationAccess &+= 1
        let relation = ancestry.relation
        let bytes = header.id.utf8.count + (relation?.parentThreadId.utf8.count ?? 0)
            + (relation?.parentAccountId?.utf8.count ?? 0) + (relation?.agentId.utf8.count ?? 0)
            + warnings.reduce(0) { $0 + $1.utf8.count }
        let previous = agentClassifications[header.id]
        let retryInterval = !ancestry.isDefinitive && previous?.ancestry.isDefinitive == false && previous?.updatedAt == header.updatedAt
            ? min((previous?.retryInterval ?? Self.unresolvedClassificationRetry) * 2, Self.maximumClassificationRetry)
            : Self.unresolvedClassificationRetry
        classificationBytes -= previous?.bytes ?? 0
        agentClassifications[header.id] = AgentClassification(ancestry: ancestry, warnings: warnings, updatedAt: header.updatedAt,
            checkedAt: now(), retryInterval: retryInterval, access: classificationAccess, bytes: bytes)
        classificationBytes += bytes
        while agentClassifications.count > Self.classificationLimit || classificationBytes > Self.classificationByteLimit {
            guard let oldest = agentClassifications.min(by: { $0.value.access < $1.value.access }) else { break }
            classificationBytes -= oldest.value.bytes
            agentClassifications.removeValue(forKey: oldest.key)
        }
    }

    private enum HistoryListError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { switch self { case .unavailable(let message): message } }
    }

    private func fetchProviderThreads(provider: AgentProvider, limit: Int, pageLimit: Int, position: ConversationListPosition,
        useStateDBOnly: Bool, pageCountLimit: Int, known: [String: ConversationHeader], read: RecentRead) async throws
        -> (threads: [ConversationHeader], unavailable: Set<String>, warnings: [String], coverageIncomplete: Bool, position: ConversationListPosition, isUnchanged: Bool) {
        guard position.canLoad else { return ([], [], [], false, .end, false) }
        let generation = epoch
        let recordsRecentPages = position == .notLoaded && pageCountLimit > 1
        let revision = (recentReadRevisions[provider] ?? 0) &+ 1
        if recordsRecentPages { recentReadRevisions[provider] = revision }
        let previousCoverage = recentCoverage[provider]
        var stoppedAtUnchanged = false
        var firstPageUnchanged = false
        var cursor = position.cursor
        var seenCursors: Set<String> = []
        var fetchedThreads: [ConversationHeader] = []
        var unavailable = Set<String>()
        var pages = 0
        var rootCount = 0

        var warnings: [String] = []
        while rootCount < limit && pages < pageCountLimit {
            let requestedLimit = read == .untilUnchanged && pages == 0 ? HistoryRefreshTiming.pollPageLimit : pageLimit
            let response: CodexAppServerV2.ThreadListResponse
            switch provider {
            case .codex: response = try await gateway.listThreads(limit: requestedLimit, cursor: cursor, useStateDBOnly: useStateDBOnly)
            case .claude: response = try await gateway.listClaudeThreads(limit: requestedLimit, cursor: cursor)
            }
            guard response.data.count <= requestedLimit else { throw GatewayClient.ClientError.invalidMessage }
            pages += 1

            let headers = response.data.map { wire in
                var header = ConversationHeader(wire)
                if let previous = known[header.id] { header.retainAncestry(from: previous) }
                return header
            }
            let classified = await classifyAgents(headers)
            rootCount += classified.threads.count(where: { !$0.isDelegatedAgent })
            warnings += classified.warnings
            var pageHeaders: [ConversationHeader] = []
            var pageUnavailable = Set<String>()
            for var header in classified.threads {
                if provider == .claude {
                    pageHeaders.append(header)
                    continue
                } else if let timestamp = response.completionTimes?[header.id] {
                    header.lastTurnCompletedAt = timestamp
                } else {
                    pageUnavailable.insert(header.id)
                }
                pageHeaders.append(header)
            }
            let unchanged = previousCoverage?.matches(pageHeaders, unavailable: pageUnavailable,
                offset: fetchedThreads.count, hasMore: response.nextCursor != nil) == true
            if pages == 1 { firstPageUnchanged = read == .untilUnchanged && unchanged }
            fetchedThreads += pageHeaders
            unavailable.formUnion(pageUnavailable)
            logger.info(
                "thread/list provider=\(provider.rawValue) page=\(pages) requested=\(requestedLimit) received=\(response.data.count) hasNextCursor=\(response.nextCursor != nil)"
            )

            guard let nextCursor = response.nextCursor else {
                cursor = nil
                break
            }
            guard !nextCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  nextCursor != cursor,
                  !response.data.isEmpty,
                  seenCursors.insert(nextCursor).inserted
            else {
                throw GatewayClient.ClientError.invalidMessage
            }
            cursor = nextCursor
            if read == .untilUnchanged, unchanged {
                stoppedAtUnchanged = true
                break
            }
        }

        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        if recordsRecentPages {
            guard recentReadRevisions[provider] == revision else { throw CancellationError() }
            if stoppedAtUnchanged, let previousCoverage {
                let tail = previousCoverage.headers.dropFirst(fetchedThreads.count)
                recentCoverage[provider] = RecentCoverage(headers: fetchedThreads + tail,
                    unavailable: unavailable.union(previousCoverage.unavailable.intersection(tail.map(\.id))),
                    hasMore: previousCoverage.hasMore)
            } else {
                recentCoverage[provider] = RecentCoverage(headers: fetchedThreads, unavailable: unavailable, hasMore: cursor != nil)
            }
        }
        let coverageIncomplete = pageCountLimit > 1 && pages == pageCountLimit && cursor != nil && rootCount < limit
        return (fetchedThreads, unavailable, Array(Set(warnings)).sorted(), coverageIncomplete,
                cursor.map(ConversationListPosition.next) ?? .end, firstPageUnchanged)
    }

    func invalidateRecentCoverage() {
        recentCoverage.removeAll()
        for provider in AgentProvider.allCases { recentReadRevisions[provider, default: 0] &+= 1 }
    }

    func invalidateAll() async {
        epoch += 1
        invalidateRecentCoverage()
        agentClassifications.removeAll()
        classificationBytes = 0
        retainedClassificationOffset = 0
        let hostID = await gateway.historyHostID
        await scheduler.invalidate(hostID: hostID)
        await cache.invalidate(hostID: hostID)
    }

    func invalidate(threadID: String) async {
        generations.invalidate(threadID)
        let hostID = await gateway.historyHostID
        await scheduler.invalidate(threadID: threadID, hostID: hostID)
        await cache.invalidate(threadID: threadID, hostID: hostID)
    }

    func invalidateAgentClassification(threadID: String) {
        if let cached = agentClassifications.removeValue(forKey: threadID) { classificationBytes -= cached.bytes }
        invalidateRecentCoverage()
    }

    func cachedConversation(header: ConversationHeader) async -> ConversationSnapshot? {
        let readEpoch = epoch
        let generation = generations[header.id]
        let key = await pageKey(header: header, request: "tail", stable: true)
        guard !Task.isCancelled, epoch == readEpoch, generations[header.id] == generation else { return nil }
        guard let entry = await cache.value(for: key, now: now()) else { return nil }
        guard !Task.isCancelled, epoch == readEpoch, generations[header.id] == generation else { return nil }
        let decoded = try? await Self.decodeWindow(entry.data)
        guard !Task.isCancelled, epoch == readEpoch, generations[header.id] == generation else { return nil }
        guard let window = decoded else {
            logger.notice("discarding incompatible materialized history cache")
            await cache.invalidate(threadID: header.id, hostID: key.hostID)
            return nil
        }
        return ConversationSnapshot(header: header, window: window, update: nil, fetchedAt: entry.fetchedAt, source: .storedTail)
    }

    func openTail(header: ConversationHeader, base: HistoryWindow?,
                  priority: HistoryReadScheduler.Priority = .foreground, bypassCache: Bool = false) async throws -> ConversationSnapshot {
        try await readTail(header: header, base: base, placement: base?.newer == nil ? .tail : .reset,
            priority: priority, bypassCache: bypassCache)
    }

    func readHeader(threadID: String) async throws -> ConversationHeader {
        try await ConversationHeader(gateway.readThread(threadID: threadID, includeTurns: false).thread)
    }

    func refreshTail(threadID: String, base: HistoryWindow?,
                     priority: HistoryReadScheduler.Priority = .reconciliation, bypassCache: Bool) async throws -> ConversationSnapshot {
        let readEpoch = epoch
        let generation = generations[threadID]
        let header = try await readHeader(threadID: threadID)
        try Task.checkCancellation()
        guard epoch == readEpoch, generations[threadID] == generation else { throw HistoryReadFailure.invalidated }
        if let base, base.newer != nil {
            return ConversationSnapshot(header: header, window: base, update: nil, fetchedAt: base.fetchedAt, source: .gateway)
        }
        let snapshot = try await readTail(header: header, base: base, placement: .tail, priority: priority, bypassCache: bypassCache)
        try Task.checkCancellation()
        guard epoch == readEpoch, generations[threadID] == generation else { throw HistoryReadFailure.invalidated }
        return snapshot
    }

    func page(header: ConversationHeader, window base: HistoryWindow, direction: CodexAppServerV2.SortDirection,
              priority: HistoryReadScheduler.Priority) async throws -> ConversationSnapshot {
        guard let cursor = direction == .desc ? base.older : base.newer else {
            return ConversationSnapshot(header: header, window: base, update: nil, fetchedAt: base.fetchedAt, source: .gateway)
        }
        let readEpoch = epoch
        let generation = generations[header.id]
        let readStartedAt = ContinuousClock.now
        do {
            var page: NativePage<ItemsResponse> = try await nativePage(header: header, method: "thread/items/list",
                cursor: cursor, direction: direction, priority: priority, limit: Self.itemPageLimit,
                settled: { $0.data.allSatisfy { $0.isComplete == true } })
            if page.source == .cachedPages, base.items.hasConflictingOverlap(with: page.value.data, fetchedAt: page.fetchedAt) {
                try Task.checkCancellation()
                guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
                page = try await nativePage(header: header, method: "thread/items/list",
                    cursor: cursor, direction: direction, priority: priority, limit: Self.itemPageLimit, bypassCache: true,
                    settled: { $0.data.allSatisfy { $0.isComplete == true } })
            }
            guard page.value.nextCursor != cursor else { throw GatewayClient.ClientError.invalidMessage }
            let placement: HistoryWindow.Placement = direction == .desc ? .older(cursor) : .newer(cursor)
            var update = HistoryWindow.Update(items: Self.measured(HistoryWindow.ItemPage(page.value.data, next: page.value.nextCursor,
                backwards: page.value.backwardsCursor, direction: direction, placement: placement, fetchedAt: page.fetchedAt), bytes: page.bytes),
                placement: placement, metadata: [])
            var window = base
            window.apply(update)
            try await coverMetadata(&update, window: &window, header: header, priority: priority, newer: direction == .asc)
            try Task.checkCancellation()
            guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
            let snapshot = ConversationSnapshot(header: header, window: window, update: update, fetchedAt: page.fetchedAt, source: page.source)
            let startedAt = min(readStartedAt, page.readStartedAt)
            if priority == .prefetch {
                deferTailCommit(snapshot, startedAt: startedAt, readStartedAt: readStartedAt, readEpoch: readEpoch, generation: generation)
            } else {
                pendingTailCommits.removeValue(forKey: header.id)?.cancel()
                try await persist(snapshot, startedAt: startedAt, readStartedAt: readStartedAt, readEpoch: readEpoch, generation: generation)
            }
            try Task.checkCancellation()
            guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
            return snapshot
        } catch let failure as GatewayRPCFailure where failure.kind == .historyCursorInvalid {
            try Task.checkCancellation()
            guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
            logger.notice("history cursor invalidated; reading the tail again")
            let snapshot = try await readTail(header: header, base: nil, placement: .reset, priority: priority, bypassCache: true)
            try Task.checkCancellation()
            guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
            return snapshot
        }
    }

    private func readTail(header: ConversationHeader, base: HistoryWindow?, placement: HistoryWindow.Placement,
                          priority: HistoryReadScheduler.Priority, bypassCache: Bool) async throws -> ConversationSnapshot {
        let readEpoch = epoch
        let generation = generations[header.id]
        let readStartedAt = ContinuousClock.now
        async let items: NativePage<ItemsResponse> = nativePage(header: header, method: "thread/items/list",
            cursor: nil, direction: .desc, priority: priority, limit: Self.tailItemPageLimit, bypassCache: bypassCache)
        async let turns: NativePage<TurnsResponse> = nativePage(header: header, method: "thread/turns/list",
            cursor: nil, direction: .desc, priority: priority, limit: Self.turnPageLimit, bypassCache: bypassCache)
        let (itemPage, turnPage) = try await (items, turns)
        let metadataPlacement: HistoryRange<CodexAppServerV2.Turn>.Placement = placement == .reset ? .reset : .tail
        var update = HistoryWindow.Update(
            items: Self.measured(HistoryWindow.ItemPage(itemPage.value.data, next: itemPage.value.nextCursor,
                backwards: itemPage.value.backwardsCursor, direction: .desc, placement: placement, fetchedAt: itemPage.fetchedAt), bytes: itemPage.bytes),
            placement: placement,
            metadata: [.init(page: Self.measured(HistoryWindow.TurnPage(turnPage.value.data, next: turnPage.value.nextCursor,
                backwards: turnPage.value.backwardsCursor, direction: .desc, placement: metadataPlacement, fetchedAt: turnPage.fetchedAt), bytes: turnPage.bytes),
                placement: metadataPlacement)])
        var window = base ?? HistoryWindow()
        if window.apply(update) {
            try await coverMetadata(&update, window: &window, header: header, priority: priority, newer: false)
        }
        try Task.checkCancellation()
        guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
        let source: ConversationSnapshot.Source = itemPage.source == .gateway && turnPage.source == .gateway ? .gateway : .cachedPages
        let snapshot = ConversationSnapshot(header: header, window: window, update: update, fetchedAt: itemPage.fetchedAt, source: source)
        try await persist(snapshot, startedAt: min(readStartedAt, itemPage.readStartedAt, turnPage.readStartedAt), readStartedAt: readStartedAt, readEpoch: readEpoch, generation: generation)
        try Task.checkCancellation()
        guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
        return snapshot
    }

    private func coverMetadata(_ update: inout HistoryWindow.Update, window: inout HistoryWindow,
                               header: ConversationHeader, priority: HistoryReadScheduler.Priority, newer: Bool) async throws {
        let readEpoch = epoch
        let generation = generations[header.id]
        for _ in 0..<Self.metadataPageLimit {
            guard !window.turnsLackingMetadata.isEmpty,
                  let cursor = newer ? window.metadata.newer : window.metadata.older else { return }
            let direction: CodexAppServerV2.SortDirection = newer ? .asc : .desc
            var page: NativePage<TurnsResponse> = try await nativePage(header: header, method: "thread/turns/list",
                cursor: cursor, direction: direction, priority: priority, limit: Self.turnPageLimit)
            if page.source == .cachedPages, window.metadata.hasConflictingOverlap(with: page.value.data, fetchedAt: page.fetchedAt) {
                try Task.checkCancellation()
                guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
                page = try await nativePage(header: header, method: "thread/turns/list",
                    cursor: cursor, direction: direction, priority: priority, limit: Self.turnPageLimit, bypassCache: true)
            }
            guard page.value.nextCursor != cursor else { throw GatewayClient.ClientError.invalidMessage }
            let placement: HistoryRange<CodexAppServerV2.Turn>.Placement = newer ? .newer(cursor) : .older(cursor)
            let turns = HistoryWindow.Update.Metadata(page: Self.measured(HistoryWindow.TurnPage(page.value.data, next: page.value.nextCursor,
                backwards: page.value.backwardsCursor, direction: direction, placement: placement, fetchedAt: page.fetchedAt), bytes: page.bytes),
                placement: placement)
            window.apply(turns)
            update.metadata.append(turns)
        }
    }

    @concurrent private static func decodePage<T: Decodable & Sendable>(_ data: Data) async throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    @concurrent private static func decodeWirePage<T: Decodable & Sendable>(_ data: Data) async throws -> (T, Data) {
        let result = try JSONDecoder().decode(RPCResult<T>.self, from: data).result
        // Keep unknown provider fields and opaque cursors, but not transport IDs.
        let content = try resultContent(in: data)
        return (result, content)
    }

    private static func resultContent(in data: Data) throws -> Data {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            func whitespace() {
                while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
            }
            func stringEnd() throws {
                guard index < bytes.count, bytes[index] == 34 else { throw GatewayClient.ClientError.invalidMessage }
                index += 1
                while index < bytes.count {
                    let byte = bytes[index]
                    index += 1
                    if byte == 34 { return }
                    if byte == 92 { index += 1 }
                }
                throw GatewayClient.ClientError.invalidMessage
            }
            whitespace()
            guard index < bytes.count, bytes[index] == 123 else { throw GatewayClient.ClientError.invalidMessage }
            index += 1
            var result: Range<Int>?
            while index < bytes.count {
                whitespace()
                if bytes[index] == 125 { break }
                let keyStart = index
                try stringEnd()
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<index]))
                whitespace()
                guard index < bytes.count, bytes[index] == 58 else { throw GatewayClient.ClientError.invalidMessage }
                index += 1
                whitespace()
                let start = index
                var depth = 0
                while index < bytes.count {
                    let byte = bytes[index]
                    if byte == 34 { try stringEnd(); continue }
                    if depth == 0, byte == 44 || byte == 125 { break }
                    if byte == 123 || byte == 91 { depth += 1 }
                    if byte == 125 || byte == 93 { depth -= 1 }
                    index += 1
                }
                if key == "result" {
                    guard result == nil else { throw GatewayClient.ClientError.invalidMessage }
                    var end = index
                    while end > start, [9, 10, 13, 32].contains(bytes[end - 1]) { end -= 1 }
                    result = start..<end
                }
                if index < bytes.count, bytes[index] == 44 { index += 1 } else { break }
            }
            guard let result else { throw GatewayClient.ClientError.invalidMessage }
            return Data(bytes[result])
        }
    }

    private static func measured<Element>(_ page: HistoryRange<Element>.Page, bytes: Int) -> HistoryRange<Element>.Page {
        var measured = page
        measured.encodedBytes = bytes
        return measured
    }

    @concurrent private static func decodeWindow(_ data: Data) async throws -> HistoryWindow {
        try JSONDecoder().decode(HistoryWindow.self, from: data)
    }

    @concurrent private static func encodeWindow(_ window: HistoryWindow) async throws -> (data: Data, fingerprint: SHA256.Digest) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let fingerprint = SHA256.hash(data: try encoder.encode(window.comparisonValue))
        return (try encoder.encode(window), fingerprint)
    }

    private func persist(_ snapshot: ConversationSnapshot, startedAt: ContinuousClock.Instant, readStartedAt: ContinuousClock.Instant, readEpoch: UInt64, generation: UInt64) async throws {
        guard snapshot.window.isLoaded, snapshot.window.newer == nil else { return }
        let key = await pageKey(header: snapshot.header, request: "tail", stable: true)
        guard let encoded = try? await Self.encodeWindow(snapshot.window),
              epoch == readEpoch, generations[snapshot.header.id] == generation else { return }
        try await cache.store(encoded.data, for: key, fetchedAt: snapshot.fetchedAt, startedAt: startedAt, readStartedAt: readStartedAt,
                              persistence: snapshot.window.hasRunningTurn ? .memoryOverDisk : .disk,
                              comparisonFingerprint: encoded.fingerprint)
    }

    private func deferTailCommit(_ snapshot: ConversationSnapshot, startedAt: ContinuousClock.Instant,
                                 readStartedAt: ContinuousClock.Instant, readEpoch: UInt64, generation: UInt64) {
        let threadID = snapshot.header.id
        pendingTailCommits[threadID]?.cancel()
        pendingTailCommits[threadID] = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.prefetchCommitDelay)) != nil else { return }
            await self?.commitTail(snapshot, startedAt: startedAt, readStartedAt: readStartedAt, readEpoch: readEpoch, generation: generation)
        }
    }

    private func commitTail(_ snapshot: ConversationSnapshot, startedAt: ContinuousClock.Instant,
                            readStartedAt: ContinuousClock.Instant, readEpoch: UInt64, generation: UInt64) async {
        guard !Task.isCancelled else { return }
        pendingTailCommits.removeValue(forKey: snapshot.header.id)
        try? await persist(snapshot, startedAt: startedAt, readStartedAt: readStartedAt, readEpoch: readEpoch, generation: generation)
    }

    private func pageKey(header: ConversationHeader, request: String, stable: Bool) async -> HistoryPageKey {
        HistoryPageKey(hostID: await gateway.historyHostID, provider: "native", threadID: header.id,
            generation: stable ? 0 : UInt64(bitPattern: header.updatedAt), request: "native-v4:\(request)")
    }

    private struct NativePage<T: Sendable>: Sendable {
        let value: T
        let fetchedAt: Date
        let bytes: Int
        let source: ConversationSnapshot.Source
        let readStartedAt: ContinuousClock.Instant
    }

    private struct RPCResult<T: Decodable & Sendable>: Decodable, Sendable { let result: T }

    private func nativePage<T: Decodable & Sendable>(header: ConversationHeader, method: String, cursor: String?,
                                                     direction: CodexAppServerV2.SortDirection, priority: HistoryReadScheduler.Priority,
                                                     limit: Int, bypassCache: Bool = false, settled: ((T) -> Bool)? = nil) async throws -> NativePage<T> {
        let failureKey = "\(header.id):\(header.updatedAt):\(method):\(direction.rawValue):\(cursor ?? "")"
        if priority != .foreground, let failure = oversizedPages[failureKey] { throw failure }
        let sizingKey = header.id + ":" + method
        let maximum = method == "thread/items/list" ? Self.itemPageLimit : Self.turnPageLimit
        let target = nextPageLimits[sizingKey] ?? maximum
        var count = min(limit, target)
        let readEpoch = epoch
        let generation = generations[header.id]
        let readStartedAt = ContinuousClock.now
        while true {
            var fields: [String: JSONValue] = ["threadId": .string(header.id), "sortDirection": .string(direction.rawValue), "limit": .number(Double(count))]
            if let cursor { fields["cursor"] = .string(cursor) }
            if method == "thread/turns/list" { fields["itemsView"] = .string("notLoaded") }
            let params = JSONValue.object(fields)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let request = method + String(decoding: try encoder.encode(params), as: UTF8.self)
            let key = await pageKey(header: header, request: request, stable: false)
            let settledKey = settled == nil || cursor == nil ? nil : await pageKey(header: header, request: "settled:" + request, stable: true)
            if !bypassCache {
                if let settledKey, let cached = await cache.value(for: settledKey, now: now()) {
                    logger.notice("history page cache=settled method=\(method) bytes=\(cached.data.count)")
                    return NativePage(value: try await Self.decodePage(cached.data), fetchedAt: cached.fetchedAt, bytes: cached.data.count,
                        source: .cachedPages, readStartedAt: cached.readStartedAt ?? readStartedAt)
                }
                if let cached = await cache.value(for: key, now: now()), cached.isFresh {
                    logger.notice("history page cache=hit method=\(method) bytes=\(cached.data.count)")
                    return NativePage(value: try await Self.decodePage(cached.data), fetchedAt: cached.fetchedAt, bytes: cached.data.count,
                        source: .cachedPages, readStartedAt: cached.readStartedAt ?? readStartedAt)
                }
            }
            do {
                let gateway = gateway
                let logger = logger
                let queuedAt = ContinuousClock.now
                let operation: @Sendable () async throws -> Data = {
                    logger.notice("history queue method=\(method) wait=\(String(describing: queuedAt.duration(to: .now))) source=\(priority.rawValue)")
                    return try await gateway.historyPageData(method: method, params: params)
                }
                let page = if bypassCache {
                    try await scheduler.readFresh(key: key, priority: priority, operation: operation)
                } else {
                    try await scheduler.read(key: key, priority: priority, operation: operation)
                }
                let data = page.data
                try Task.checkCancellation()
                guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
                let decodeStart = ContinuousClock.now
                let (result, content): (T, Data) = try await Self.decodeWirePage(data)
                try Task.checkCancellation()
                guard epoch == readEpoch, generations[header.id] == generation else { throw HistoryReadFailure.invalidated }
                let decodeTime = decodeStart.duration(to: .now)
                if nextPageLimits.count > 64 { nextPageLimits.removeAll() }
                if data.count > 1024 * 1024 { nextPageLimits[sizingKey] = max(1, count * 1024 * 1024 / data.count) }
                else if data.count < 512 * 1024, count == target { nextPageLimits[sizingKey] = min(maximum, count * 2) }
                logger.notice("history decode method=\(method) elapsed=\(String(describing: decodeTime))")
                let fetchedAt = now()
                let storeKey = settledKey.flatMap { settledKey in settled?(result) == true ? settledKey : nil } ?? key
                try await cache.store(content, for: storeKey, fetchedAt: fetchedAt, startedAt: page.startedAt, readStartedAt: readStartedAt, persistence: cursor == nil ? .memory : .disk)
                logger.notice("history page method=\(method) bytes=\(data.count) source=\(priority.rawValue) count=\(count)")
                return NativePage(value: result, fetchedAt: fetchedAt, bytes: content.count, source: .gateway, readStartedAt: page.startedAt)
            } catch let failure as GatewayRPCFailure where failure.historyPageSize != nil && count > 1 {
                count = max(1, count / 2)
            } catch let failure as GatewayRPCFailure where failure.historyPageSize != nil {
                if oversizedPages.count >= 64 { oversizedPages.removeAll() }
                oversizedPages[failureKey] = failure
                throw failure
            } catch let error as GatewayClient.ClientError {
                if case .historyCapacity = error {
                    if oversizedPages.count >= 64 { oversizedPages.removeAll() }
                    oversizedPages[failureKey] = error
                }
                throw error
            }
        }
    }

    func diagnosticCounters() async -> (pendingReads: Int, waiters: Int, cacheBytes: Int) {
        let reads = await scheduler.statistics(hostID: gateway.historyHostID)
        return (reads.pending + reads.running, reads.waiters, await cache.totalMemoryBytes)
    }
}
