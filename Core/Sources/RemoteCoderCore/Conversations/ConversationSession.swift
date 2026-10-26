import Foundation
import OSLog

actor ConversationSession {
    enum ObservationError: LocalizedError {
        case superseded, capacity
        var errorDescription: String? {
            switch self {
            case .superseded: "Conversation observation was superseded."
            case .capacity: "Live catch-up exceeded its buffer. Retry to recover the latest conversation."
            }
        }
    }

    private struct ObservationBuffer {
        let id: UUID
        var events: [TurnScopedGatewayEvent] = []
        var itemIDs: Set<String> = []
        var bytes = 0
        var overflow = false
    }
    private var observationBuffer: ObservationBuffer?
    private var observationReceipt: GatewayWireReceipt?
    private var observationID: UUID?

    nonisolated let conversationID: UUID
    nonisolated let identity: UUID
    nonisolated let readingPosition = TranscriptReadingPosition()
    nonisolated let rowPresentations = TranscriptRowPresentations()
    private var state: ConversationState
    private let checkpoints: ConversationCheckpointStore
    private let checkpointGeneration: UInt64
    private enum Restoration {
        case unloaded
        case loading(UUID, Task<ConversationCheckpointStore.LoadResult, Error>)
        case ready
        case failed(any Error)
    }
    private var restoration: Restoration = .unloaded
    private var requiresAuthoritativeHistory = false
    private var persistenceTask: Task<Void, Never>?
    private var persistenceTaskID: UUID?
    private var savedPersistenceRevision: UInt64?
    private var historyOmitted = false
    private var deferredRemoteChanges = false
    static let streamingPublicationInterval: Duration = .milliseconds(80)
    private static let minimumPublicationInterval: Duration = .milliseconds(16)
    private var projectionTask: Task<Void, Never>?
    private var projectionPause: Task<Void, Never>?
    private var lastProjection: ContinuousClock.Instant?
    private var hasUrgentChange = false
    private var projectionPublication = ConversationProjection.Publication()
    private let projectionSignposter: OSSignposter
    private var observers: [UUID: AsyncStream<ConversationSnapshot>.Continuation] = [:]
    private var successor: ConversationSession?
    #if RC_PERF_HARNESS
    private var perfStreamTurnID: String?

    func preparePerfStream(threadID: String, turnID: String) throws {
        guard successor == nil, state.threadID == threadID, perfStreamTurnID == nil,
              state.turns[turnID] == nil, !hasActiveTurn, state.submissions.isEmpty, observationBuffer == nil,
              case .ready = restoration else { throw PerfStreamFailure.unavailable }
        perfStreamTurnID = turnID
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceTaskID = nil
    }

    func ingestPerfStream(_ event: TurnScopedGatewayEvent) async throws {
        guard successor == nil, observationBuffer == nil, event.turnID == perfStreamTurnID,
              event.threadID == state.threadID else { throw PerfStreamFailure.superseded }
        await ingest(event, replay: false)
    }

    private enum PerfStreamFailure: LocalizedError {
        case unavailable, superseded

        var errorDescription: String? {
            switch self {
            case .unavailable: "Streaming bench needs a restored, idle conversation with no pending submissions or observation."
            case .superseded: "Streaming bench session was replaced or began a new gateway observation."
            }
        }
    }
    #endif
    private let logger = AppLogger(category: "ConversationSession")

    init(conversationID: UUID, threadID: String? = nil, checkpoints: ConversationCheckpointStore, checkpointGeneration: UInt64,
        projectionSignposter: OSSignposter = ConversationProjection.signposter) {
        self.conversationID = conversationID
        self.projectionSignposter = projectionSignposter
        self.identity = UUID()
        self.state = ConversationState(conversationID: conversationID, threadID: threadID, ownerID: identity)
        self.checkpoints = checkpoints
        self.checkpointGeneration = checkpointGeneration
    }

    func bind(threadID: String) {
        precondition(state.threadID == nil || state.threadID == threadID)
        guard state.threadID != threadID else { return }
        state.threadID = threadID
        state.markPersistedChange()
        schedulePersistence()
    }

    /// Opening/reopening a conversation explicitly retries a failed read. A failed
    /// read never authorizes a write, even when live events have arrived meanwhile.
    func restore() async throws {
        if let successor { try await successor.restore(); return }
        if case .ready = restoration { return }
        let id: UUID
        let task: Task<ConversationCheckpointStore.LoadResult, Error>
        if case .loading(let currentID, let currentTask) = restoration {
            id = currentID
            task = currentTask
        } else {
            id = UUID()
            task = Task { [checkpoints, conversationID, checkpointGeneration, threadID = state.threadID] in
                try await checkpoints.restore(conversationID, threadID: threadID, generation: checkpointGeneration)
            }
            restoration = .loading(id, task)
        }
        do {
            let result = try await task.value
            let saved = result.checkpoint
            guard case .loading(let currentID, _) = restoration, currentID == id else { return }
            if let successor {
                try await successor.restore()
                if let saved { await successor.restoreCheckpoint(saved) }
            } else if let saved {
                state.restore(saved)
                savedPersistenceRevision = max(savedPersistenceRevision ?? 0, saved.durableRevision)
            }
            requiresAuthoritativeHistory = result.requiresAuthoritativeHistory || saved == nil && state.threadID != nil
            restoration = .ready
        } catch {
            if case .loading(let currentID, _) = restoration, currentID == id {
                restoration = .failed(error)
                if !(error is ConversationCheckpointStore.CapacityOverflow) {
                    logger.error("Conversation restore failed; checkpoint preserved: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    /// Timers and shutdown may persist only after a successful read. They do not
    /// retry an unreadable checkpoint on every streaming update.
    private func prepareForPersistence() async throws {
        if case .failed(let error) = restoration { throw error }
        try await restore()
    }

    func snapshot() async -> ConversationSnapshot {
        if let successor { return await successor.snapshot() }
        return await render()
    }

    private func render() async -> ConversationSnapshot {
        let prepared = await ConversationProjection.render(state, memo: projectionPublication.preparationMemo, signposter: projectionSignposter)
        if let snapshot = projectionPublication.apply(prepared, currentRevision: state.revision) {
            await rowPresentations.prepareSource(snapshot, readingPosition: readingPosition)
            return snapshot
        }
        return prepared.snapshot
    }

    func snapshots() -> AsyncStream<ConversationSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.removeObserver(id) } }
            scheduleProjection()
            if deferredRemoteChanges || historyOmitted { schedulePersistence() }
        }
    }

    func ingest(_ event: TurnScopedGatewayEvent, replay: Bool) async {
        guard !Task.isCancelled else { return }
        if let successor { await successor.ingest(event, replay: replay); return }
        if let baseline = observationReceipt, let receipt = event.note.receipt {
            if receipt.connection == baseline.connection, receipt.sequence <= baseline.sequence { return }
            if observationID != nil, observationBuffer == nil, receipt.connection != baseline.connection { return }
        }
        if var buffer = observationBuffer, !replay {
            if !buffer.overflow {
                buffer.bytes += (try? JSONEncoder().encode(event.note.params).count) ?? 0
                if let id = event.itemID {
                    buffer.itemIDs.insert("\(event.turnID)|\(id)")
                }
                if buffer.bytes > 4 * 1024 * 1024 || buffer.itemIDs.count > 200 || buffer.events.count >= 8192 {
                    buffer.overflow = true
                    buffer.events.removeAll()
                } else { buffer.events.append(event) }
            }
            observationBuffer = buffer
            return
        }
        // The subscription checkpoint owns replay for its selected conversation.
        if observationBuffer != nil, replay { return }
        let previous = state.revision
        let previousPersistence = state.persistenceRevision
        state.apply(event, replay: replay)
        guard state.revision != previous else { return }
        guard state.persistenceRevision != previousPersistence else { scheduleStreamingProjection(); return }
        scheduleProjection()
        if event.method == "turn/completed" { await persistLocalChanges() }
        else { scheduleRemotePersistence() }
    }

    func revokeStreamingPrefixes() async {
        if let successor { await successor.revokeStreamingPrefixes(); return }
        state.revokeStreamingPrefixes()
    }

    func beginCompaction(_ requestID: UUID) async -> Bool {
        if let successor { return await successor.beginCompaction(requestID) }
        guard state.beginCompaction(requestID) else { return false }
        scheduleProjection()
        return true
    }

    func compactionRequestFailed(_ requestID: UUID, message: String, deliveryUncertain: Bool) async {
        if let successor {
            await successor.compactionRequestFailed(requestID, message: message, deliveryUncertain: deliveryUncertain)
            return
        }
        state.compactionRequestFailed(requestID, message: message, deliveryUncertain: deliveryUncertain)
        scheduleProjection()
    }

    func compactionIdleConfirmed(requestID: UUID?, turnID: String?) async {
        if let successor { await successor.compactionIdleConfirmed(requestID: requestID, turnID: turnID); return }
        state.compactionIdleConfirmed(requestID: requestID, turnID: turnID)
        scheduleProjection()
    }

    func beginHistoryRead() async -> ConversationState.HistoryRead {
        if let successor { return await successor.beginHistoryRead() }
        return state.beginHistoryRead()
    }

    func beginObservation(_ id: UUID) {
        observationID = id
        observationBuffer = ObservationBuffer(id: id)
    }

    func cancelObservation(_ id: UUID) {
        guard observationID == id else { return }
        observationBuffer = nil
        observationID = nil
    }

    func finishObservation(
        _ id: UUID, receipt: GatewayWireReceipt, header: ConversationHeader,
        checkpoint: CodexAppServerV2.ThreadObservationCheckpoint,
        history: GatewayHistoryService.ObservationHistory,
        read: ConversationState.HistoryRead
    ) throws {
        guard let buffer = observationBuffer, buffer.id == id else { throw ObservationError.superseded }
        guard !buffer.overflow else { throw ObservationError.capacity }
        state.mergeObservation(header: header, checkpoint: checkpoint, history: history, read: read)
        for event in buffer.events {
            guard let eventReceipt = event.note.receipt, eventReceipt.connection == receipt.connection,
                  eventReceipt.sequence > receipt.sequence else { continue }
            state.apply(event, replay: false)
        }
        observationBuffer = nil
        observationReceipt = receipt
        scheduleRemotePersistence()
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func scheduleProjection() {
        hasUrgentChange = true
        projectionPause?.cancel()
        scheduleStreamingProjection()
    }

    private func scheduleStreamingProjection() {
        guard projectionTask == nil, !observers.isEmpty else { return }
        projectionTask = Task { [weak self] in await self?.publishSnapshots() }
    }

    private func publishSnapshots() async {
        defer { projectionTask = nil }
        var rendered: UInt64?
        while rendered != state.revision, !Task.isCancelled, !observers.isEmpty {
            if let lastProjection {
                let due = lastProjection + (hasUrgentChange ? Self.minimumPublicationInterval : Self.streamingPublicationInterval)
                if due > .now {
                    await pauseProjection(until: due)
                    continue
                }
            }
            hasUrgentChange = false
            lastProjection = .now
            let snapshot = await render()
            rendered = snapshot.revision
            #if RC_PERF_HARNESS
            PerfBuild.count("sessionPublish")
            #endif
            for observer in observers.values { observer.yield(snapshot) }
        }
    }

    private func pauseProjection(until due: ContinuousClock.Instant) async {
        let pause = Task { _ = try? await Task.sleep(until: due) }
        projectionPause = pause
        await pause.value
        projectionPause = nil
    }

    func submit(_ message: ChatMessage, input: String? = nil, expectedQuestionVersion: QuestionVersion? = nil) async throws -> ConversationSnapshot {
        try await restore()
        try Task.checkCancellation()
        if let successor { return try await successor.submit(message, input: input, expectedQuestionVersion: expectedQuestionVersion) }
        try state.validateQuestionSubmission(message, input: input, expectedVersion: expectedQuestionVersion)
        state.submit(message, input: input)
        scheduleProjection()
        return await snapshot()
    }

    func submitToQueue(_ message: ChatMessage, input: String) async throws -> ConversationSnapshot {
        try await restore()
        try Task.checkCancellation()
        if let successor { return try await successor.submitToQueue(message, input: input) }
        state.submitToQueue(message, input: input)
        scheduleProjection()
        return await snapshot()
    }

    /// A submission is shown at once but dispatched only after this succeeds,
    /// so recovery never automatically sends it again.
    func persistSubmission(_ messageID: UUID) async throws {
        if let successor { try await successor.persistSubmission(messageID); return }
        do { try await saveSubmission(messageID) }
        catch { state.submissionNotDispatched(messageID); scheduleProjection(); throw error }
    }

    private func saveSubmission(_ messageID: UUID) async throws {
        guard let submission = state.submissions[messageID] else { throw CancellationError() }
        let record = ConversationCheckpointStore.SubmissionRecord(revision: state.persistenceRevision,
            threadID: state.threadID, submission: submission)
        try await checkpoints.saveSubmission(record, conversationID: conversationID, generation: checkpointGeneration)
        schedulePersistence()
    }

    func queued(_ messageID: UUID, submission: CodexAppServerV2.QueuedSubmission) async {
        if let successor { await successor.queued(messageID, submission: submission); return }
        state.queued(messageID, submission: submission)
        await persistLocalChanges()
    }

    func queueRemoved(_ messageID: UUID) async {
        if let successor { await successor.queueRemoved(messageID); return }
        state.queueRemoved(messageID)
        await persistLocalChanges()
    }

    func queuedSubmissionID(for messageID: UUID) async -> String? {
        if let successor { return await successor.queuedSubmissionID(for: messageID) }
        return state.queuedSubmissionID(for: messageID)
    }

    func hasQueueReceipts() async -> Bool {
        if let successor { return await successor.hasQueueReceipts() }
        return state.hasQueueReceipts
    }

    func beginQueueRead() async -> ConversationState.QueueRead {
        if let successor { return await successor.beginQueueRead() }
        return state.beginQueueRead()
    }

    func applyQueue(_ entries: [CodexAppServerV2.QueuedSubmission], read: ConversationState.QueueRead,
                    threadIsIdle: Bool) async {
        if let successor { await successor.applyQueue(entries, read: read, threadIsIdle: threadIsIdle); return }
        let previous = state.persistenceRevision
        state.applyQueue(entries, read: read, threadIsIdle: threadIsIdle)
        if state.persistenceRevision != previous { await persistLocalChanges() }
    }

    func accepted(_ messageID: UUID, turnID: String) async {
        if let successor { await successor.accepted(messageID, turnID: turnID); return }
        state.accepted(messageID, turnID: turnID)
        await persistLocalChanges()
    }

    func submissionFailed(_ messageID: UUID, failure: ConversationState.SubmissionFailure) async {
        if let successor { await successor.submissionFailed(messageID, failure: failure); return }
        state.submissionFailed(messageID, failure: failure)
        await persistLocalChanges()
    }

    func appendLocal(_ message: ChatMessage, turnID: String? = nil) async {
        if let successor { await successor.appendLocal(message, turnID: turnID); return }
        state.appendLocal(message, turnID: turnID)
        await persistLocalChanges()
    }

    func merge(_ observation: GatewayHistoryService.ConversationSnapshot, read: ConversationState.HistoryRead) async -> ConversationSnapshot {
        if let successor { return await successor.merge(observation, read: read) }
        state.merge(observation, read: read)
        scheduleRemotePersistence()
        return await snapshot()
    }

    func validTokenUsage() async -> CodexAppServerV2.ThreadTokenUsage? {
        if let successor { return await successor.validTokenUsage() }
        return state.validTokenUsage
    }

    func recordTokenUsage(turnID: String, usage: CodexAppServerV2.ThreadTokenUsage) async {
        if let successor { await successor.recordTokenUsage(turnID: turnID, usage: usage); return }
        state.recordTokenUsage(turnID: turnID, usage: usage)
        scheduleRemotePersistence()
    }

    func takeDiscardedSteers(of turnID: String) async -> ConversationState.Submission? {
        if let successor { return await successor.takeDiscardedSteers(of: turnID) }
        let previous = state.persistenceRevision
        let steers = state.takeDiscardedSteers(of: turnID)
        if state.persistenceRevision != previous { await persistLocalChanges() }
        return steers
    }

    func deliveryIsUncertain(_ messageID: UUID) async -> Bool {
        if let successor { return await successor.deliveryIsUncertain(messageID) }
        return state.submissions[messageID]?.status == .uncertain
    }

    func reconcileDeliveryEvidence(_ snapshot: GatewayHistoryService.ConversationSnapshot) async {
        if let successor { await successor.reconcileDeliveryEvidence(snapshot); return }
        if state.reconcileDeliveryEvidence(snapshot) { schedulePersistence() }
    }

    func mergeQuestions(_ incoming: QuestionHostSnapshot) async throws -> ConversationSnapshot {
        try await restore()
        if let successor { return try await successor.mergeQuestions(incoming) }
        guard incoming.threadId == state.threadID else { throw GatewayClient.ClientError.invalidMessage }
        var inventory = state.questions ?? QuestionInventory()
        try inventory.merge(incoming)
        let previous = state.questions
        state.questions = inventory
        let receiptsChanged = state.confirmQuestionReceipts()
        let dismissalsBefore = state.questionDismissals?.count
        if inventory.coverage == .ready {
            state.questionDismissals = state.questionDismissals?.filter { itemID, intent in
                intent.expectedEpoch == inventory.epoch && inventory.records[itemID]?.isPending != false
            }
        }
        let recordsChanged = previous?.epoch != inventory.epoch
            || (previous?.records ?? [:]) != inventory.records
        if recordsChanged || receiptsChanged || dismissalsBefore != state.questionDismissals?.count {
            state.markPersistedChange()
            schedulePersistence()
        } else if previous?.coverage != inventory.coverage || previous?.reason != inventory.reason
                    || previous?.pendingItemIDs != inventory.pendingItemIDs {
            state.revision += 1
            scheduleProjection()
        }
        return await snapshot()
    }

    func invalidateQuestions(_ reason: String) async {
        if let successor { await successor.invalidateQuestions(reason); return }
        guard var inventory = state.questions else { return }
        inventory.invalidate(reason)
        guard inventory != state.questions else { return }
        state.questions = inventory
        state.revision += 1
        scheduleProjection()
    }

    func prepareQuestionDismissal(itemID: String, version: QuestionVersion) async throws -> QuestionDismissal {
        try await restore()
        if let successor { return try await successor.prepareQuestionDismissal(itemID: itemID, version: version) }
        if let existing = state.questionDismissals?[itemID], existing.expectedEpoch == state.questions?.epoch { return existing }
        guard let threadID = state.threadID, state.questions?.coverage == .ready,
              state.questions?.epoch == version.epoch, state.questions?.records[itemID]?.revision == version.revision else { throw ConversationState.QuestionSubmissionError.stale }
        let request = QuestionDismissal(threadId: threadID, itemId: itemID, expectedRecordRevision: version.revision, expectedEpoch: version.epoch, mutationId: UUID())
        if state.questionDismissals == nil { state.questionDismissals = [:] }
        state.questionDismissals?[itemID] = request
        state.markPersistedChange()
        do { try await persist() }
        catch { state.questionDismissals?.removeValue(forKey: itemID); throw error }
        return request
    }

    func finishQuestionDismissal(itemID: String) async throws {
        if let successor { try await successor.finishQuestionDismissal(itemID: itemID); return }
        state.questionDismissals?.removeValue(forKey: itemID)
        state.markPersistedChange()
        try await persist()
    }

    func authorizeQuestionResend(_ messageID: UUID) async throws {
        if let successor { try await successor.authorizeQuestionResend(messageID); return }
        guard let pending = state.submissions[messageID], pending.questionEntries != nil,
              pending.status == .uncertain || pending.status == .accepted else { return }
        state.submissions[messageID]?.status = .failed
        state.markPersistedChange()
        do { try await persist() }
        catch { state.submissions[messageID] = pending; throw error }
        scheduleProjection()
    }

    func activity(turnID: String, active: Bool) async {
        if let successor { await successor.activity(turnID: turnID, active: active); return }
        let previous = state.revision
        state.activity(turnID: turnID, active: active)
        if state.revision != previous { scheduleProjection() }
    }

    func synchronizeActivity(activeTurnID: String?) async {
        if let successor { await successor.synchronizeActivity(activeTurnID: activeTurnID); return }
        let previous = state.revision
        if let activeTurnID { state.activity(turnID: activeTurnID, active: true) }
        for id in state.order {
            #if RC_PERF_HARNESS
            if id == perfStreamTurnID { continue }
            #endif
            state.activity(turnID: id, active: activeTurnID.map { GatewayNotificationRouting.normalizeTurnID($0) == GatewayNotificationRouting.normalizeTurnID(id) } == true)
        }
        if state.revision != previous { scheduleProjection() }
    }

    func toggleGroup(_ id: String) async {
        if let successor { await successor.toggleGroup(id); return }
        state.toggleTimeline(id)
        scheduleProjection()
    }

    var canEvict: Bool { observers.isEmpty && state.submissions.isEmpty }
    private var hasActiveTurn: Bool { state.turns.values.contains(where: \.isActive) }
    var evictionRevision: UInt64? { canEvict ? state.revision : nil }

    func resetEventSequences() {
        state.resetEventSequences()
    }

    /// Notifications may introduce a newly created server thread before its draft is bound.
    /// Transfer those facts once; already queued deliveries follow the new owner.
    func handoff(to session: ConversationSession) -> ConversationState.Checkpoint {
        precondition(successor == nil)
        successor = session
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceTaskID = nil
        projectionTask?.cancel()
        projectionPause?.cancel()
        projectionPublication = ConversationProjection.Publication()
        observers.values.forEach { $0.finish() }
        observers.removeAll()
        #if RC_PERF_HARNESS
        if let perfStreamTurnID {
            var transferred = state
            transferred.turns.removeValue(forKey: perfStreamTurnID)
            transferred.order.removeAll { $0 == perfStreamTurnID }
            return transferred.checkpoint
        }
        #endif
        return state.checkpoint
    }

    func restoreCheckpoint(_ saved: ConversationState.Checkpoint, live: Bool = false) {
        state.restore(saved, live: live)
        schedulePersistence()
        scheduleProjection()
    }

    func flush() async throws {
        if let successor { try await successor.flush(); return }
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceTaskID = nil
        state.commitLiveChanges()
        try await persist()
    }

    private func persist() async throws {
        #if RC_PERF_HARNESS
        guard perfStreamTurnID == nil else { return }
        #endif
        try await prepareForPersistence()
        if let successor { try await successor.flush(); return }
        #if RC_PERF_HARNESS
        guard perfStreamTurnID == nil else { return }
        #endif
        guard !awaitingAuthoritativeHistory else { return }
        let checkpoint = state.checkpoint
        let presented = !observers.isEmpty
        if let savedPersistenceRevision, checkpoint.durableRevision <= savedPersistenceRevision, !(historyOmitted && presented) {
            PersistenceMetrics.shared.skipped(.checkpoints)
            return
        }
        let receipt = try await checkpoints.save(checkpoint, conversationID: conversationID, generation: checkpointGeneration,
                                                 presented: presented)
        guard case .ready = restoration, successor == nil else { return }
        state.applyUnavailableImages(receipt.unavailableImages)
        savedPersistenceRevision = max(savedPersistenceRevision ?? 0, checkpoint.durableRevision)
        historyOmitted = !receipt.historyAdmitted
        deferredRemoteChanges = false
    }

    private func persistLocalChanges() async {
        do { try await persist() }
        catch {
            if !(error is ConversationCheckpointStore.CapacityOverflow) {
                logger.error("Conversation checkpoint failed: \(error.localizedDescription)")
            }
        }
        scheduleProjection()
    }

    private var awaitingAuthoritativeHistory: Bool {
        requiresAuthoritativeHistory && state.window == nil && state.order.isEmpty && !state.checkpoint.containsLocalRecords
    }

    private var needsPersistence: Bool {
        savedPersistenceRevision != state.persistenceRevision || historyOmitted && !observers.isEmpty
    }

    private func scheduleRemotePersistence() {
        guard observers.isEmpty else { schedulePersistence(); return }
        deferredRemoteChanges = true
    }

    private func schedulePersistence() {
        scheduleProjection()
        guard !awaitingAuthoritativeHistory else { return }
        #if RC_PERF_HARNESS
        guard perfStreamTurnID == nil else { return }
        #endif
        if case .failed = restoration { return }
        guard needsPersistence, persistenceTask == nil else { return }
        let id = UUID()
        let delay: Duration = hasActiveTurn ? .seconds(5) : .seconds(1)
        persistenceTaskID = id
        persistenceTask = Task { [weak self] in
            var succeeded = false
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                try await self?.persist()
                succeeded = true
            } catch is CancellationError {} catch {
                if !(error is ConversationCheckpointStore.CapacityOverflow) {
                    self?.logger.error("Conversation checkpoint failed: \(error.localizedDescription)")
                }
            }
            await self?.finishPersistence(id: id, succeeded: succeeded)
        }
    }

    private func finishPersistence(id: UUID, succeeded: Bool) {
        guard persistenceTaskID == id else { return }
        persistenceTask = nil
        persistenceTaskID = nil
        // A change that arrived during the save is coalesced into the next snapshot.
        // Failure stays dirty; a later change or explicit flush can retry it.
        if succeeded, needsPersistence { schedulePersistence() }
    }

}

/// The host owns identity bindings; each conversation independently owns its transcript.
actor ConversationSessions {
    private let logger = AppLogger(category: "ConversationSessions")
    private final class WeakSession {
        weak var value: ConversationSession?
        init(_ value: ConversationSession) { self.value = value }
    }
    private let checkpoints: ConversationCheckpointStore
    private let sessionIndex: ConversationIndex
    private let contentSubscriptions: any ConversationContentSubscriptions
    private var contentSubscriptionRevision: UInt64 = 0
    private var publishedContentSubscriptions: Set<String> = []
    private let projectionSignposter: OSSignposter
    private var notificationEpoch: String?
    private var byID: [UUID: ConversationSession] = [:]
    private var references: [UUID: WeakSession] = [:]
    private var invalidations: [UUID: Task<Void, Never>] = [:]
    private struct Epoch {
        var value: UInt64
        var creations = 0
        var checkpointGeneration: UInt64?
    }
    private var epochs: [UUID: Epoch] = [:]
    private var nextEpoch: UInt64 = 0
    private var releases: [UUID: Task<Void, Never>] = [:]
    private var byThread: [String: UUID] = [:]
    private var recency: [UUID] = []
    private var drafts: Set<UUID> = []
    private var access: [UUID: UInt64] = [:]

    init(hostID: UUID, sessionIndex: ConversationIndex,
        contentSubscriptions: any ConversationContentSubscriptions, storage: HostStorage = .live,
        projectionSignposter: OSSignposter = ConversationProjection.signposter) {
        checkpoints = ConversationCheckpointStore(hostID: hostID, storage: storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        self.sessionIndex = sessionIndex
        self.contentSubscriptions = contentSubscriptions
        self.projectionSignposter = projectionSignposter
    }

    func checkpointInventory() async -> CheckpointInventory? {
        await checkpoints.inventory()
    }

    func session(conversationID: UUID, threadID: String? = nil) async -> ConversationSession {
        await pruneUnretainedReferences()
        let draft = drafts.contains(conversationID) ? byID[conversationID] : nil
        let id = draft == nil ? (threadID.flatMap { retainedID(for: $0) } ?? conversationID) : conversationID
        if epochs[id] == nil {
            nextEpoch += 1
            epochs[id] = Epoch(value: nextEpoch)
        }
        epochs[id]?.creations += 1
        let session: ConversationSession
        while true {
            if let current = byID[id] ?? references[id]?.value { session = current; break }
            guard let epoch = epochs[id]?.value else { preconditionFailure("Session creation has no epoch") }
            await releases[id]?.value
            await invalidations[id]?.value
            let generation = await checkpoints.generation(for: id)
            let previousGeneration = epochs[id]?.checkpointGeneration ?? 0
            epochs[id]?.checkpointGeneration = max(previousGeneration, generation)
            await pruneUnretainedReferences()
            guard epochs[id]?.value == epoch else { continue }
            session = byID[id] ?? references[id]?.value ?? ConversationSession(conversationID: id, threadID: threadID,
                checkpoints: checkpoints, checkpointGeneration: generation, projectionSignposter: projectionSignposter)
            break
        }
        let admitted = byID.updateValue(session, forKey: id) == nil
        references[id] = WeakSession(session)
        recency.removeAll { $0 == id }
        recency.append(id)
        access[id, default: 0] += 1
        if let threadID {
            let previousID = byThread[threadID]
            byThread[threadID] = id
            drafts.remove(id)
            let previous = previousID.flatMap { $0 == id ? nil : (byID.removeValue(forKey: $0) ?? references[$0]?.value) }
            if let previousID, previousID != id { recency.removeAll { $0 == previousID }; access.removeValue(forKey: previousID) }
            await session.bind(threadID: threadID)
            if let previous { await session.restoreCheckpoint(previous.handoff(to: session), live: true) }
        } else if byThread.values.contains(id) == false { drafts.insert(id) }
        epochs[id]?.creations -= 1
        if admitted { await evictIdle(keeping: [id]) }
        else { await publishContentSubscriptions() }
        return session
    }

    func session(threadID: String) async -> ConversationSession {
        await pruneUnretainedReferences()
        if let existing = existingSession(threadID: threadID) {
            await publishContentSubscriptions()
            return existing
        }
        var bound = retainedID(for: threadID)
        if bound == nil { bound = await sessionIndex.conversationID(for: threadID) }
        return await session(conversationID: bound ?? ChatMessage.deterministicID(for: threadID), threadID: threadID)
    }

    func ingest(_ event: TurnScopedGatewayEvent, replay: Bool) async {
        await existingSession(threadID: event.threadID)?.ingest(event, replay: replay)
        if event.method == "turn/completed" { await evictIdle(keeping: []) }
    }

    func synchronizeActivity(_ activeTurns: Set<RunningTurn>) async {
        let activeByThread = Dictionary(uniqueKeysWithValues: activeTurns.map { ($0.threadID, $0.turnID) })
        let owners = byThread.compactMap { threadID, _ in existingSession(threadID: threadID).map { (threadID, $0) } }
        for (threadID, session) in owners {
            await session.synchronizeActivity(activeTurnID: activeByThread[threadID])
        }
    }

    func existingSession(threadID: String) -> ConversationSession? {
        guard let id = retainedID(for: threadID) else { return nil }
        return byID[id] ?? references[id]?.value
    }

    func revokeStreamingPrefixes() async {
        for session in references.values.compactMap(\.value) { await session.revokeStreamingPrefixes() }
    }

    func adoptNotificationEpoch(_ epoch: String) async {
        let previous = notificationEpoch
        notificationEpoch = epoch
        guard let previous, previous != epoch else { return }
        for session in references.values.compactMap(\.value) { await session.resetEventSequences() }
    }

    func evictIdle(keeping conversationIDs: Set<UUID>) async {
        guard byID.count > 16 else { await publishContentSubscriptions(); return }
        for id in recency where byID.count > 16 && !conversationIDs.contains(id) {
            let generation = access[id]
            guard let session = byID[id], let revision = await session.evictionRevision else { continue }
            do { try await session.flush() } catch { continue }
            let currentRevision = await session.evictionRevision
            guard byID[id] === session, generation == access[id], revision == currentRevision else { continue }
            byID.removeValue(forKey: id)
            recency.removeAll { $0 == id }
            drafts.remove(id)
            access.removeValue(forKey: id)
        }
        await publishContentSubscriptions()
    }

    private func publishContentSubscriptions() async {
        await pruneUnretainedReferences()
        let threads = Set(byThread.keys.filter { $0.hasPrefix("claude_") && existingSession(threadID: $0) != nil })
        guard threads != publishedContentSubscriptions else { return }
        publishedContentSubscriptions = threads
        contentSubscriptionRevision += 1
        await contentSubscriptions.replaceContentSubscriptions(threadIDs: threads, revision: contentSubscriptionRevision)
    }

    private func retainedID(for threadID: String) -> UUID? {
        guard let id = byThread[threadID] else { return nil }
        guard byID[id] != nil || references[id]?.value != nil else {
            byThread.removeValue(forKey: threadID)
            references.removeValue(forKey: id)
            return nil
        }
        return id
    }

    var retainedEpochCount: Int { epochs.count }
    var retainedCheckpointFenceCount: Int {
        get async { await checkpoints.retainedFenceCount }
    }

    private func pruneUnretainedReferences() async {
        references = references.filter { byID[$0.key] != nil || $0.value.value != nil }
        byThread = byThread.filter { byID[$0.value] != nil || references[$0.value] != nil }
        let retired = epochs.filter { id, epoch in
            byID[id] == nil && references[id] == nil && epoch.creations == 0 && invalidations[id] == nil && releases[id] == nil
        }
        for (id, epoch) in retired {
            if let generation = epoch.checkpointGeneration {
                releases[id] = Task { [checkpoints] in await checkpoints.release(id, generation: generation) }
            } else {
                epochs.removeValue(forKey: id)
            }
        }
        for (id, epoch) in retired where epoch.checkpointGeneration != nil {
            await releases[id]?.value
            releases.removeValue(forKey: id)
            if byID[id] == nil, references[id]?.value == nil, epochs[id]?.creations == 0, invalidations[id] == nil {
                epochs.removeValue(forKey: id)
            }
        }
    }

    struct FlushFailure: Sendable {
        let conversationID: UUID
        let reason: String
    }

    @discardableResult
    func flush() async -> [FlushFailure] {
        let sessions = references.values.compactMap(\.value)
        var failures: [FlushFailure] = []
        for session in sessions {
            do { try await session.flush() }
            catch { failures.append(FlushFailure(conversationID: session.conversationID, reason: error.localizedDescription)) }
        }
        return failures
    }

    func invalidate(threadID: String) async {
        guard let id = byThread[threadID] else { return }
        await releases[id]?.value
        if let pending = invalidations[id] { await pending.value; return }
        nextEpoch += 1
        if epochs[id] == nil { epochs[id] = Epoch(value: nextEpoch) }
        else { epochs[id]?.value = nextEpoch }
        byID.removeValue(forKey: id)
        references.removeValue(forKey: id)
        byThread = byThread.filter { $0.value != id }
        recency.removeAll { $0 == id }
        drafts.remove(id)
        access.removeValue(forKey: id)
        let task = Task { [checkpoints, logger] in
            do { try await checkpoints.remove(id) }
            catch { logger.error("Conversation invalidation failed; cleanup will retry on admission: \(error.localizedDescription)") }
        }
        invalidations[id] = task
        await publishContentSubscriptions()
        await task.value
        invalidations.removeValue(forKey: id)
        await pruneUnretainedReferences()
    }

    func openThreadIDs() -> [String] {
        byThread.compactMap { threadID, id in byID[id] == nil ? nil : threadID }
    }
}
