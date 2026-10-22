import Foundation
import Observation

struct TrackedTurn: Equatable, Sendable {
    let threadID: String
    let turnID: String
    let jobID: String
}

struct DispatchedTurn: Equatable, Sendable {
    let conversationID: UUID
    let threadID: String
    let turnID: String
    var finalReply: String?
}

struct TurnRegistryChange: Equatable, Sendable {
    let countBefore: Int
    let countAfter: Int
}

struct CompletedTurn: Equatable, Sendable {
    let threadID: String
    let normalizedTurnID: String
    let jobID: String
    let change: TurnRegistryChange
}

enum TurnAdoption: Equatable, Sendable {
    case ignored
    case unchanged
    case adopted(TurnRegistryChange)
}

struct SessionDecision: Equatable, Sendable {
    let threadID: String
    let decision: GatewayBusyDecision
}

struct SnapshotOutcome: Sendable {
    let snapshot: CodexGatewayDaemon.ActiveTurnsResponse
    let decisions: [SessionDecision]
    let change: TurnRegistryChange
}

@MainActor @Observable
final class TurnRegistry {
    private var turnsByThreadID: [String: TrackedTurn] = [:]
    private(set) var jobs: [ActiveJob] = []
    private var inflightCountsByConversationID: [UUID: Int] = [:]
    private var inflightCountsByThreadID: [String: Int] = [:]
    private var steerCountsByThreadID: [String: Int] = [:]
    @ObservationIgnored private var dispatchedTurnsByJobID: [String: DispatchedTurn] = [:]
    @ObservationIgnored private var tombstones = CompletedTurnTombstones()
    @ObservationIgnored private var replayedJobIDs: Set<String> = []
    @ObservationIgnored private var missingSinceByThreadID: [String: Date] = [:]
    @ObservationIgnored private var ownersByThreadID: [String: String] = [:]

    var trackedThreadIDs: Set<String> { Set(turnsByThreadID.keys) }

    var runningTurns: Set<RunningTurn> {
        Set(turnsByThreadID.values.map { RunningTurn(threadID: $0.threadID, turnID: $0.turnID) })
    }

    var busyThreadIDs: Set<String> {
        Set(turnsByThreadID.keys)
            .union(inflightCountsByThreadID.keys)
            .union(jobs.map(\.threadID))
    }

    var liveActivityTaskCount: Int {
        max(
            Set(jobs.map { owner(ofThread: $0.threadID) }).count,
            Set(turnsByThreadID.keys.map(owner(ofThread:))).count,
            inflightCountsByConversationID.count,
            inflightCountsByThreadID.count
        )
    }

    var isIdle: Bool { liveActivityTaskCount == 0 }

    func owner(ofThread threadID: String) -> String {
        ownersByThreadID[threadID] ?? threadID
    }

    func turn(forThread threadID: String) -> TrackedTurn? {
        turnsByThreadID[threadID]
    }

    var dispatchedTurns: [DispatchedTurn] { Array(dispatchedTurnsByJobID.values) }

    func dispatchedTurn(id jobID: String) -> DispatchedTurn? {
        dispatchedTurnsByJobID[jobID]
    }

    func hasCompleted(threadID: String, turnID: String) -> Bool {
        tombstones.contains(threadID: threadID, normalizedTurnID: GatewayNotificationRouting.normalizeTurnID(turnID))
    }

    func isBusy(conversationID: UUID, threadID: String?) -> Bool {
        inflightCountsByConversationID[conversationID] != nil
            || threadID.map { inflightCountsByThreadID[$0] != nil || turnsByThreadID[$0] != nil } == true
    }

    func isSteering(threadID: String) -> Bool {
        steerCountsByThreadID[threadID] != nil
    }

    func register(_ job: ActiveJob) -> TurnRegistryChange {
        measuring {
            jobs.removeAll { $0.id == job.id }
            jobs.append(job)
        }
    }

    func acceptDispatch(_ job: ActiveJob, turn: TrackedTurn, conversationID: UUID) -> TurnRegistryChange {
        measuring {
            dispatchedTurnsByJobID[job.id] = DispatchedTurn(
                conversationID: conversationID, threadID: job.threadID, turnID: turn.turnID)
            turnsByThreadID[turn.threadID] = turn
            jobs.removeAll { $0.id == job.id }
            jobs.append(job)
        }
    }

    func recordFinalReply(_ text: String, jobID: String) {
        dispatchedTurnsByJobID[jobID]?.finalReply = text
    }

    func finishDispatched(jobID: String) -> DispatchedTurn? {
        dispatchedTurnsByJobID.removeValue(forKey: jobID)
    }

    func endAllDispatched() {
        dispatchedTurnsByJobID.removeAll()
    }

    func adopt(threadID: String, turnID: String) -> TurnAdoption {
        let normalizedTurnID = GatewayNotificationRouting.normalizeTurnID(turnID)
        guard !tombstones.contains(threadID: threadID, normalizedTurnID: normalizedTurnID) else { return .ignored }
        missingSinceByThreadID[threadID] = nil
        let existing = turnsByThreadID[threadID]
        guard existing.map({ GatewayNotificationRouting.normalizeTurnID($0.turnID) }) != normalizedTurnID else {
            return .unchanged
        }
        let jobID = GatewayNotificationRouting.jobID(threadID: threadID, turnID: turnID)
        return .adopted(measuring {
            if let existing { jobs.removeAll { $0.id == existing.jobID } }
            turnsByThreadID[threadID] = TrackedTurn(threadID: threadID, turnID: turnID, jobID: jobID)
            jobs.removeAll { $0.id == jobID }
            jobs.append(ActiveJob(id: jobID, threadID: threadID))
        })
    }

    func complete(threadID: String, turnID: String) -> CompletedTurn? {
        let normalizedTurnID = GatewayNotificationRouting.normalizeTurnID(turnID)
        guard !tombstones.contains(threadID: threadID, normalizedTurnID: normalizedTurnID) else { return nil }
        let jobID = GatewayNotificationRouting.jobID(threadID: threadID, turnID: normalizedTurnID)
        let tracked = turnsByThreadID[threadID]
        let trackedIsCompleted = tracked.map { GatewayNotificationRouting.normalizeTurnID($0.turnID) == normalizedTurnID } == true
        let change = measuring {
            tombstones.record(threadID: threadID, normalizedTurnID: normalizedTurnID)
            replayedJobIDs.remove(jobID)
            dispatchedTurnsByJobID[jobID] = nil
            if trackedIsCompleted { turnsByThreadID[threadID] = nil }
            missingSinceByThreadID[threadID] = nil
            jobs.removeAll { $0.id == jobID }
        }
        return CompletedTurn(threadID: threadID, normalizedTurnID: normalizedTurnID, jobID: jobID, change: change)
    }

    func retire(jobID: String, threadID: String, turnID: String?) -> TurnRegistryChange {
        measuring { retireInPlace(jobID: jobID, threadID: threadID, turnID: turnID) }
    }

    func clearTurn(threadID: String, turnID: String) -> TurnRegistryChange {
        let normalizedTurnID = GatewayNotificationRouting.normalizeTurnID(turnID)
        let matched = turnsByThreadID[threadID].flatMap {
            GatewayNotificationRouting.normalizeTurnID($0.turnID) == normalizedTurnID ? $0 : nil
        }
        let jobID = matched?.jobID ?? GatewayNotificationRouting.jobID(threadID: threadID, turnID: normalizedTurnID)
        return measuring {
            if matched != nil { turnsByThreadID[threadID] = nil }
            missingSinceByThreadID[threadID] = nil
            jobs.removeAll { $0.id == jobID }
        }
    }

    func apply(
        _ reported: CodexGatewayDaemon.ActiveTurnsResponse,
        observedAt now: Date
    ) -> SnapshotOutcome {
        let before = liveActivityTaskCount
        let snapshot = CodexGatewayDaemon.ActiveTurnsResponse(
            epoch: reported.epoch,
            revision: reported.revision,
            activeTurns: reported.activeTurns.filter { !hasCompleted(threadID: $0.threadId, turnID: $0.turnId) },
            coverage: reported.coverage,
            externalActivity: reported.externalActivity,
            agentOwners: reported.agentOwnersCoverage == .unavailable
                ? ownersByThreadID.merging(reported.agentOwners) { _, incoming in incoming }
                : reported.agentOwners,
            agentOwnersCoverage: reported.agentOwnersCoverage
        )
        ownersByThreadID = snapshot.agentOwners
        for entry in snapshot.activeTurns {
            let turnID = GatewayNotificationRouting.normalizeTurnID(entry.turnId)
            let jobID = GatewayNotificationRouting.jobID(threadID: entry.threadId, turnID: turnID)
            missingSinceByThreadID[entry.threadId] = nil
            let existing = turnsByThreadID[entry.threadId]
            if existing?.turnID != entry.turnId || existing?.jobID != jobID {
                if let existing { jobs.removeAll { $0.id == existing.jobID } }
                turnsByThreadID[entry.threadId] = TrackedTurn(threadID: entry.threadId, turnID: entry.turnId, jobID: jobID)
            }
            if !jobs.contains(where: { $0.id == jobID }) {
                jobs.append(ActiveJob(id: jobID, threadID: entry.threadId))
            }
        }

        var decisions: [SessionDecision] = []
        for session in locallyBusySessions() {
            let threadID = session.sessionID
            let decision = Self.decide(
                session,
                snapshot: snapshot,
                missingSince: missingSinceByThreadID[threadID],
                observedAt: now
            )
            switch decision {
            case .keepActive:
                break
            case .unknown:
                missingSinceByThreadID[threadID] = nil
            case .pending(let since):
                missingSinceByThreadID[threadID] = since
            case .retire(let jobIDs, _):
                missingSinceByThreadID[threadID] = nil
                for jobID in jobIDs.sorted() {
                    retireInPlace(
                        jobID: jobID,
                        threadID: threadID,
                        turnID: GatewayNotificationRouting.normalizedTurnID(fromJobID: jobID, threadID: threadID)
                    )
                }
            }
            decisions.append(SessionDecision(threadID: threadID, decision: decision))
        }
        return SnapshotOutcome(
            snapshot: snapshot,
            decisions: decisions,
            change: TurnRegistryChange(countBefore: before, countAfter: liveActivityTaskCount)
        )
    }

    func clearAllMissing() {
        missingSinceByThreadID.removeAll()
    }

    func claimReplay(jobID: String) -> Bool {
        replayedJobIDs.insert(jobID).inserted
    }

    func releaseReplay(jobID: String) {
        replayedJobIDs.remove(jobID)
    }

    func lock(conversationID: UUID, threadID: String?) -> TurnRegistryChange {
        measuring {
            inflightCountsByConversationID[conversationID, default: 0] += 1
            if let threadID { inflightCountsByThreadID[threadID, default: 0] += 1 }
        }
    }

    func lockThread(_ threadID: String) -> TurnRegistryChange {
        measuring { inflightCountsByThreadID[threadID, default: 0] += 1 }
    }

    func unlock(conversationID: UUID, threadID: String?) -> TurnRegistryChange {
        measuring {
            Self.decrement(&inflightCountsByConversationID, key: conversationID)
            if let threadID { Self.decrement(&inflightCountsByThreadID, key: threadID) }
        }
    }

    func beginSteer(threadID: String) {
        steerCountsByThreadID[threadID, default: 0] += 1
    }

    func endSteer(threadID: String) {
        Self.decrement(&steerCountsByThreadID, key: threadID)
    }

    func removeAll() -> TurnRegistryChange {
        measuring {
            turnsByThreadID.removeAll()
            jobs.removeAll()
            dispatchedTurnsByJobID.removeAll()
            replayedJobIDs.removeAll()
            missingSinceByThreadID.removeAll()
        }
    }

    private func measuring(_ mutation: () -> Void) -> TurnRegistryChange {
        let before = liveActivityTaskCount
        mutation()
        return TurnRegistryChange(countBefore: before, countAfter: liveActivityTaskCount)
    }

    private func retireInPlace(jobID: String, threadID: String, turnID: String?) {
        if let turnID {
            tombstones.record(threadID: threadID, normalizedTurnID: GatewayNotificationRouting.normalizeTurnID(turnID))
        }
        if turnsByThreadID[threadID]?.jobID == jobID {
            turnsByThreadID[threadID] = nil
            missingSinceByThreadID[threadID] = nil
        }
        dispatchedTurnsByJobID[jobID] = nil
        jobs.removeAll { $0.id == jobID }
    }

    private func locallyBusySessions() -> [GatewayBusySession] {
        var jobIDsByThreadID: [String: Set<String>] = [:]
        for job in jobs { jobIDsByThreadID[job.threadID, default: []].insert(job.id) }
        return Set(turnsByThreadID.keys).union(jobIDsByThreadID.keys).sorted().map { threadID in
            GatewayBusySession(
                sessionID: threadID,
                activeJobID: turnsByThreadID[threadID]?.jobID,
                processingJobIDs: jobIDsByThreadID[threadID] ?? [],
                hasPendingDispatch: inflightCountsByThreadID[threadID, default: 0] > 0
            )
        }
    }

    private static func decrement<Key: Hashable>(_ counts: inout [Key: Int], key: Key) {
        guard let current = counts[key] else { return }
        if current > 1 { counts[key] = current - 1 } else { counts[key] = nil }
    }
}

/// One session's locally tracked gateway work.
///
/// The chat view model tracks busy state in three places — the active-turn map,
/// the processing rows behind the history spinner, and the inflight dispatch
/// counts. Only the first used to be reconciled against the daemon, so a
/// processing row that lost its turn pinned the history row on "Working" until
/// relaunch.
struct GatewayBusySession: Equatable, Sendable {
    let sessionID: String
    /// Exact job id of the tracked active turn, when the app has one.
    let activeJobID: String?
    /// Exact job ids of this session's processing rows.
    let processingJobIDs: Set<String>
    /// A dispatch whose `turn/start` has not returned, so the daemon cannot have
    /// published it. The inflight lock is released as soon as the turn is
    /// accepted, so a running turn stays retirable.
    let hasPendingDispatch: Bool

    init(
        sessionID: String,
        activeJobID: String? = nil,
        processingJobIDs: Set<String> = [],
        hasPendingDispatch: Bool = false
    ) {
        self.sessionID = sessionID
        self.activeJobID = activeJobID
        self.processingJobIDs = processingJobIDs
        self.hasPendingDispatch = hasPendingDispatch
    }
}

/// What the daemon's active-turn snapshot says to do with one busy session.
enum GatewayBusyDecision: Equatable, Sendable {
    /// The daemon reports a turn for this session.
    case keepActive
    /// Inactivity cannot be confirmed. Keep local state, reset confirmations.
    case unknown
    /// Missing since this instant, not yet for the whole confirmation window.
    case pending(since: Date)
    /// Confirmed inactive: retire exactly these job ids.
    case retire(jobIDs: Set<String>, clearsActiveTurn: Bool)
}

enum MissingTurnObservation: Equatable, Sendable {
    case pending(since: Date)
    case confirmed
}

extension TurnRegistry {
    nonisolated static let confirmationWindow: TimeInterval = 1

    nonisolated static func missingObservation(since: Date?, at now: Date) -> MissingTurnObservation {
        guard let since else { return .pending(since: now) }
        return now.timeIntervalSince(since) >= confirmationWindow ? .confirmed : .pending(since: since)
    }

    /// Pure so the rules stay testable without a live gateway.
    nonisolated static func decide(
        _ session: GatewayBusySession,
        snapshot: CodexGatewayDaemon.ActiveTurnsResponse,
        missingSince: Date?,
        observedAt now: Date
    ) -> GatewayBusyDecision {
        if snapshot.activeTurns.contains(where: { $0.threadId == session.sessionID }) {
            return .keepActive
        }
        // Unknown coverage is not proof of inactivity.
        guard snapshot.canConfirmInactivity(for: session.sessionID) else { return .unknown }

        // Protects the window where `turn/start` has not returned.
        guard session.hasPendingDispatch == false else { return .unknown }

        if case .pending(let since) = missingObservation(since: missingSince, at: now) { return .pending(since: since) }

        var jobIDs = session.processingJobIDs
        if let activeJobID = session.activeJobID { jobIDs.insert(activeJobID) }
        return .retire(jobIDs: jobIDs, clearsActiveTurn: session.activeJobID != nil)
    }
}

/// Per-thread record of turns whose completion the app already applied, so a
/// late or replayed notification cannot re-register a retired job. A replay
/// batch is ordered and may contain more than eight completions for one Claude
/// thread; retaining 64 prevents eviction inside that batch from reopening an
/// older turn on the next replay. Turn ids are stored normalized (see
/// `GatewayNotificationRouting.normalizeTurnID`).
struct CompletedTurnTombstones: Equatable, Sendable {
    private var idsByThreadID: [String: [String]] = [:]
    private let limitPerThread: Int

    init(limitPerThread: Int = 64) {
        self.limitPerThread = limitPerThread
    }

    mutating func record(threadID: String, normalizedTurnID: String) {
        var ids = idsByThreadID[threadID, default: []]
        ids.removeAll { $0 == normalizedTurnID }
        ids.append(normalizedTurnID)
        if ids.count > limitPerThread { ids.removeFirst(ids.count - limitPerThread) }
        idsByThreadID[threadID] = ids
    }

    func contains(threadID: String, normalizedTurnID: String) -> Bool {
        idsByThreadID[threadID]?.contains(normalizedTurnID) == true
    }
}
