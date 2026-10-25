import Foundation
import OSLog

@MainActor
protocol TurnDispatchHost: AnyObject {
    var isRetired: Bool { get }
    func feedbackForCurrentConversation() -> (HapticEvent) -> Void
    func isVisibleConversation(_ conversationID: UUID, sessionID: String?) -> Bool
    func speakIfOwningAudio(_ text: String)
    func turnsChanged(_ change: TurnRegistryChange)
    func synchronizeConversationActivity()
    func retireGatewayJob(threadID: String, turnID: String?, jobID: String)
    func startActivityRefresh()
    func reconcileInputDelivery(threadID: String) async
    func threadStarted(_ thread: CodexAppServerV2.Thread, session: ConversationSession, settingsRevision: UInt64,
                       requestedServiceTier: CodexAppServerV2.ServiceTierOverride?, admittedSettings: TurnDispatcher.Settings?) async
    func selectionIsCurrent(revision: UInt64, threadID: String) -> Bool
}

@MainActor
final class TurnDispatcher {
    struct Settings {
        let model: ModelOption
        let reasoning: ReasoningSelection
        let serviceTier: CodexAppServerV2.ServiceTierOverride?
        let fastModeState: FastModeState
        let workingDirectory: String?
        let selectionRevision: UInt64

        func admitted(to thread: CodexAppServerV2.Thread) -> Self {
            let provider = AgentProvider.provider(forThreadID: thread.id)
            let modelProvider = ThreadModelProvider(thread.modelProvider, threadID: thread.id)
            let id = thread.model ?? model.id
            let changedRoute = provider != model.provider || id != model.id ||
                modelProvider?.externalID != model.modelProvider?.id
            let effort = thread.reasoningEffort.flatMap { ReasoningEffort(rawValue: $0.rawValue) }
            let fastMode = thread.extra?.fastModeSelection
            let resolved: ModelOption
            if changedRoute {
                resolved = (provider == .claude ? ClaudeModelCatalog.model(for: id) : nil)
                    ?? .unlisted(id: id, modelProvider: modelProvider?.modelProvider,
                        reportedEffort: effort, reportedFastMode: fastMode == true)
            } else {
                resolved = model
            }
            return Self(model: resolved,
                reasoning: !changedRoute && reasoning == .automatic ? .automatic
                    : effort.map(ReasoningSelection.effort) ?? (changedRoute ? .automatic : reasoning),
                serviceTier: fastMode.map { $0 ? .set(.fast) : .clear } ?? (changedRoute ? .clear : serviceTier),
                fastModeState: changedRoute ? .readback(fastMode, remembered: fastMode) : fastModeState.reading(thread.extra),
                workingDirectory: workingDirectory, selectionRevision: selectionRevision)
        }
    }

    struct Submission {
        let draft: ComposerDraft
        let conversationID: UUID
        let userMessageID: UUID
        let input: String
        let interactionMode: CodexInteractionMode
        let settings: Settings
    }

    struct FollowUp {
        let conversationID: UUID
        let draft: ComposerDraft
        let settings: Settings
    }

    private struct StoppedTurn {
        enum Outcome { case pending, succeeded, failed }

        let id = UUID()
        let turn: RunningTurn
        let followUp: FollowUp?
        var outcome = Outcome.pending
        var completed = false
        var continuing = false
    }

    private enum QueueSelection { case receipt(UUID), first }

    private weak var host: (any TurnDispatchHost)?
    private let gateway: GatewayClient
    private let turns: TurnRegistry
    private let stops: TurnStops
    private let conversations: ConversationSessions
    private let sessionIndex: ConversationIndex
    private let metadata: ConversationMetadataService
    private let drafts: ComposerDraftStore
    private let logger = AppLogger(category: "TurnDispatcher")
    private let tasks = OwnedTasks<UUID>()
    private let queueReads = OwnedTasks<String>()
    private var acceptsWork = true
    private var queueChangeTails: [String: UUID] = [:]
    private var stoppedTurns: [RunningTurn: StoppedTurn] = [:]
    private var inflightSteers: [RunningTurn: Int] = [:]

    init(host: any TurnDispatchHost, gateway: GatewayClient, turns: TurnRegistry, stops: TurnStops,
         conversations: ConversationSessions, sessionIndex: ConversationIndex, metadata: ConversationMetadataService,
         drafts: ComposerDraftStore) {
        self.host = host
        self.gateway = gateway
        self.turns = turns
        self.stops = stops
        self.conversations = conversations
        self.sessionIndex = sessionIndex
        self.metadata = metadata
        self.drafts = drafts
    }

    private var isClosed: Bool { !acceptsWork || (host?.isRetired ?? true) }

    @discardableResult
    func cancelAll() -> [Task<Void, Never>] {
        clearStoppedTurns()
        return tasks.cancelAll() + queueReads.cancelAll()
    }

    private func clearStoppedTurns() {
        for stopped in stoppedTurns.values {
            if let followUp = stopped.followUp { unlock(conversationID: followUp.conversationID, sessionID: stopped.turn.threadID) }
        }
        stoppedTurns.removeAll()
    }

    func quiesce() {
        acceptsWork = false
        clearStoppedTurns()
        tasks.quiesce()
        queueReads.quiesce()
    }

    func drain() async {
        await tasks.drain()
        await queueReads.drain()
    }

    func resume() {
        acceptsWork = true
        tasks.resume()
        queueReads.resume()
    }

    func stop(_ turn: RunningTurn, followUp: FollowUp?, feedback: @escaping (HapticEvent) -> Void) {
        guard !isClosed, !stops.isStopping(turn) else { return }
        let key = Self.normalized(turn)
        if let previous = stoppedTurns[key] {
            guard previous.outcome != .pending, !previous.continuing else { return }
            finishStoppedTurn(key, id: previous.id)
        }
        logger.notice("stop requested thread=\(turn.threadID) turn=\(turn.turnID)")
        let stopped = StoppedTurn(turn: turn, followUp: followUp)
        stoppedTurns[key] = stopped
        if let followUp { lock(conversationID: followUp.conversationID, sessionID: turn.threadID) }
        tasks.start(UUID()) { [self] in
            do {
                try Task.checkCancellation()
                guard !isClosed else { return }
                try await stops.stop(turn)
                try Task.checkCancellation()
                guard !isClosed else { return }
                if stoppedTurns[key]?.id == stopped.id { stoppedTurns[key]?.outcome = .succeeded }
                host?.startActivityRefresh()
            } catch is CancellationError {
                if stoppedTurns[key]?.id == stopped.id { stoppedTurns[key]?.outcome = .failed }
            } catch {
                logger.error("stop refused thread=\(turn.threadID) turn=\(turn.turnID) error=\(error.localizedDescription)")
                if stoppedTurns[key]?.id == stopped.id { stoppedTurns[key]?.outcome = .failed }
                continueStoppedTurn(key)
                guard !isClosed else { return }
                if case .turnNotRunning = (error as? GatewayRPCFailure)?.kind {
                    host?.startActivityRefresh()
                    return
                }
                feedback(.error)
                stops.fail(turn, message: Self.stopFailureMessage(error))
            }
            continueStoppedTurn(key)
        }
    }

    func turnCompleted(threadID: String, turnID: String) {
        let key = Self.normalized(RunningTurn(threadID: threadID, turnID: turnID))
        stoppedTurns[key]?.completed = true
        continueStoppedTurn(key)
    }

    private func continueStoppedTurn(_ key: RunningTurn) {
        guard let stopped = stoppedTurns[key], !stopped.continuing, inflightSteers[key] == nil else { return }
        if stopped.outcome == .failed {
            finishStoppedTurn(key, id: stopped.id)
            return
        }
        guard stopped.completed, stopped.outcome == .succeeded, !isClosed else { return }
        stoppedTurns[key]?.continuing = true
        guard let followUp = stopped.followUp else { finishStoppedTurn(key, id: stopped.id); return }
        tasks.start(UUID()) { [self] in
            defer { finishStoppedTurn(key, id: stopped.id) }
            let session = await conversations.session(conversationID: followUp.conversationID, threadID: key.threadID)
            guard !isClosed, !Task.isCancelled, stoppedTurns[key]?.id == stopped.id,
                  turns.turn(forThread: key.threadID) == nil else { return }
            if let steers = await session.takeDiscardedSteers(of: stopped.turn.turnID) {
                guard !isClosed, !Task.isCancelled, stoppedTurns[key]?.id == stopped.id else {
                    await session.submissionFailed(steers.message.id, failure: .notDispatched)
                    return
                }
                startTurn(Submission(draft: followUp.draft, conversationID: followUp.conversationID,
                    userMessageID: steers.message.id, input: steers.input, interactionMode: .text,
                    settings: followUp.settings), sessionID: key.threadID)
            } else if AgentProvider.provider(forThreadID: key.threadID) == .codex {
                guard !isClosed, !Task.isCancelled, stoppedTurns[key]?.id == stopped.id else { return }
                startQueued(.first, conversationID: followUp.conversationID, threadID: key.threadID, settings: followUp.settings)
            }
        }
    }

    private func finishStoppedTurn(_ key: RunningTurn, id: UUID) {
        guard let stopped = stoppedTurns[key], stopped.id == id else { return }
        stoppedTurns[key] = nil
        if let followUp = stopped.followUp { unlock(conversationID: followUp.conversationID, sessionID: stopped.turn.threadID) }
    }

    private static func normalized(_ turn: RunningTurn) -> RunningTurn {
        RunningTurn(threadID: turn.threadID, turnID: GatewayNotificationRouting.normalizeTurnID(turn.turnID))
    }

    func steer(_ submission: Submission, activeTurn: TrackedTurn) {
        guard let host, !isClosed else { return }
        let key = Self.normalized(RunningTurn(threadID: activeTurn.threadID, turnID: activeTurn.turnID))
        let id = UUID()
        let stoppedAfterCompletion = stoppedTurns[key]?.completed == true
        if !stoppedAfterCompletion { inflightSteers[key, default: 0] += 1 }
        let feedback = host.feedbackForCurrentConversation()
        turns.beginSteer(threadID: activeTurn.threadID)
        tasks.start(id) { [self] in
            defer {
                turns.endSteer(threadID: activeTurn.threadID)
                if !stoppedAfterCompletion, let count = inflightSteers[key] {
                    inflightSteers[key] = count > 1 ? count - 1 : nil
                }
                continueStoppedTurn(key)
            }
            let session = await conversations.session(conversationID: submission.conversationID, threadID: activeTurn.threadID)
            guard !stoppedAfterCompletion else {
                await session.submissionFailed(submission.userMessageID, failure: .notDispatched)
                return
            }
            do {
                try Task.checkCancellation()
                guard !isClosed else { throw CancellationError() }
                _ = try await gateway.steerTurn(threadID: activeTurn.threadID, expectedTurnID: activeTurn.turnID,
                    clientUserMessageID: submission.userMessageID.uuidString, input: submission.input,
                    additionalContext: submission.interactionMode.additionalContext)
                await session.accepted(submission.userMessageID, turnID: activeTurn.turnID)
            } catch {
                if case .turnNotRunning = (error as? GatewayRPCFailure)?.kind,
                   stoppedTurns[key] == nil, !isClosed, !Task.isCancelled {
                    host.retireGatewayJob(threadID: activeTurn.threadID, turnID: activeTurn.turnID, jobID: activeTurn.jobID)
                    startTurn(submission, sessionID: activeTurn.threadID)
                } else {
                    if !(error is CancellationError) { feedback(.error) }
                    let failure = Self.inputDeliveryFailure(error)
                    await session.submissionFailed(submission.userMessageID, failure: failure)
                    if case .uncertain = failure {
                        await host.reconcileInputDelivery(threadID: activeTurn.threadID)
                        guard !isClosed, await session.deliveryIsUncertain(submission.userMessageID) else { return }
                    }
                    await appendLocalReply("⛔️ \(failure.userMessage)", conversationID: submission.conversationID,
                                           sessionID: activeTurn.threadID)
                }
            }
        }
    }

    func queue(messageID: UUID, conversationID: UUID, threadID: String, input: String) {
        guard let host, !isClosed else { return }
        let feedback = host.feedbackForCurrentConversation()
        changeQueue(threadID: threadID) { [self] in
            let session = await conversations.session(conversationID: conversationID, threadID: threadID)
            do {
                let queued = try await gateway.queueMessage(threadID: threadID, clientUserMessageID: messageID.uuidString,
                    input: input)
                await session.queued(messageID, submission: queued)
            } catch is CancellationError {
                await session.submissionFailed(messageID, failure: .uncertain("Queueing was interrupted"))
            } catch {
                feedback(.error)
                let failure = Self.inputDeliveryFailure(error)
                await session.submissionFailed(messageID, failure: failure)
                await appendLocalReply("⛔️ \(failure.userMessage)", conversationID: conversationID, sessionID: threadID)
                if case .uncertain = failure { reconcileQueue(threadID: threadID) }
            }
        }
    }

    func reconcileQueue(threadID: String) {
        guard AgentProvider.provider(forThreadID: threadID) == .codex, !isClosed else { return }
        queueReads.start(threadID) { [self] in
            guard await conversations.openThreadIDs().contains(threadID) else { return }
            let session = await conversations.session(threadID: threadID)
            guard await session.hasQueueReceipts() else { return }
            let read = await session.beginQueueRead()
            do {
                let entries = try await gateway.queuedMessages(threadID: threadID)
                let activity = try await gateway.readActiveTurns()
                try Task.checkCancellation()
                guard !isClosed else { return }
                let idle = activity.canConfirmInactivity(for: threadID)
                    && ConversationActivity(snapshot: activity).state(for: threadID) == .idle
                await session.applyQueue(entries, read: read, threadIsIdle: idle)
            } catch is CancellationError {
            } catch {
                logger.notice("queue read failed thread=\(threadID) error=\(error.localizedDescription)")
            }
        }
    }

    func startQueued(messageID: UUID, conversationID: UUID, threadID: String, settings: Settings) {
        startQueued(.receipt(messageID), conversationID: conversationID, threadID: threadID, settings: settings)
    }

    private func startQueued(_ selection: QueueSelection, conversationID: UUID, threadID: String, settings: Settings) {
        guard let host, !isClosed else { return }
        let feedback = host.feedbackForCurrentConversation()
        lock(conversationID: conversationID, sessionID: threadID)
        changeQueue(threadID: threadID) { [self] in
            defer { unlock(conversationID: conversationID, sessionID: threadID) }
            let session = await conversations.session(conversationID: conversationID, threadID: threadID)
            do {
                try Task.checkCancellation()
                guard !isClosed else { return }
                let queued: CodexAppServerV2.QueuedSubmission
                switch selection {
                case .receipt(let messageID):
                    guard let id = await session.queuedSubmissionID(for: messageID) else { return }
                    queued = CodexAppServerV2.QueuedSubmission(id: id, clientUserMessageId: messageID.uuidString)
                case .first:
                    guard let first = try await gateway.queuedMessages(threadID: threadID).first else { return }
                    queued = first
                }
                try Task.checkCancellation()
                guard !isClosed else { return }
                try await gateway.verifyDispatchAllowed(to: threadID)
                try Task.checkCancellation()
                guard !isClosed else { return }
                let thread = try await gateway.startOrResumeThread(threadID: threadID, model: settings.model.id,
                    cwd: settings.workingDirectory, serviceTier: settings.serviceTier, provider: .codex)
                await host.threadStarted(thread, session: session, settingsRevision: settings.selectionRevision,
                                         requestedServiceTier: settings.serviceTier, admittedSettings: nil)
                try Task.checkCancellation()
                guard !isClosed else { return }
                let turnID = try await gateway.startQueuedMessage(threadID: threadID, queuedSubmissionID: queued.id)
                if !turns.hasCompleted(threadID: threadID, turnID: turnID) {
                    let jobID = GatewayNotificationRouting.jobID(threadID: threadID, turnID: turnID)
                    host.turnsChanged(turns.acceptDispatch(
                        ActiveJob(id: jobID, threadID: threadID),
                        turn: TrackedTurn(threadID: threadID, turnID: turnID, jobID: jobID),
                        conversationID: conversationID
                    ))
                    host.synchronizeConversationActivity()
                }
                if let messageID = UUID(uuidString: queued.clientUserMessageId) {
                    await session.accepted(messageID, turnID: turnID)
                }
            } catch is CancellationError {
                reconcileQueue(threadID: threadID)
            } catch {
                feedback(.error)
                await appendLocalReply("⛔️ \(error.localizedDescription)", conversationID: conversationID, sessionID: threadID)
                reconcileQueue(threadID: threadID)
            }
        }
    }

    func removeQueued(messageID: UUID, conversationID: UUID, threadID: String) {
        guard let host, !isClosed else { return }
        let feedback = host.feedbackForCurrentConversation()
        changeQueue(threadID: threadID) { [self] in
            let session = await conversations.session(conversationID: conversationID, threadID: threadID)
            guard let queuedSubmissionID = await session.queuedSubmissionID(for: messageID) else { return }
            do {
                if try await gateway.deleteQueuedMessage(threadID: threadID, queuedSubmissionID: queuedSubmissionID) {
                    await session.queueRemoved(messageID)
                } else {
                    reconcileQueue(threadID: threadID)
                }
            } catch is CancellationError {
                reconcileQueue(threadID: threadID)
            } catch {
                feedback(.error)
                await appendLocalReply("⛔️ \(error.localizedDescription)", conversationID: conversationID, sessionID: threadID)
                reconcileQueue(threadID: threadID)
            }
        }
    }

    private func changeQueue(threadID: String, _ operation: @escaping @MainActor () async -> Void) {
        guard !isClosed else { return }
        let previous = queueChangeTails[threadID]
        let id = UUID()
        queueChangeTails[threadID] = id
        tasks.start(id) { [self] in
            if let previous { await tasks.value(previous) }
            await operation()
            if queueChangeTails[threadID] == id { queueChangeTails[threadID] = nil }
        }
    }

    func startTurn(_ submission: Submission, sessionID: String?) {
        guard let host, !isClosed else { return }
        let feedback = host.feedbackForCurrentConversation()
        let conversationID = submission.conversationID
        let userMessageID = submission.userMessageID
        let settings = submission.settings
        let started = ContinuousClock.now
        lock(conversationID: conversationID, sessionID: sessionID)

        tasks.start(UUID()) { [self] in
            var resolvedSessionID: String?
            var dispatchAttempted = false

            defer {
                unlock(conversationID: conversationID, sessionID: resolvedSessionID ?? sessionID)
            }

            do {
                try Task.checkCancellation()
                try await gateway.verifyDispatchAllowed(to: sessionID)
                try Task.checkCancellation()
                guard !isClosed else { return }
                // An existing thread already belongs to a provider; only a new
                // one takes its provider from the selected model.
                let provider = sessionID.map(AgentProvider.provider(forThreadID:)) ?? settings.model.provider
                let cwd = settings.workingDirectory
                // Claude runs the CLI in the working directory and has no
                // fallback the way Codex does, so an unset one must fail here
                // rather than as an opaque -32602 from the gateway.
                if provider == .claude, cwd?.isEmpty != false {
                    throw AgentProviderError.workingDirectoryRequired(provider)
                }

                guard !isClosed else { return }
                let thread = try await gateway.startOrResumeThread(
                    threadID: sessionID,
                    model: settings.model.id,
                    cwd: cwd,
                    serviceTier: settings.serviceTier,
                    provider: provider,
                    effort: settings.reasoning.effort?.rawValue
                )
                let settings = sessionID == nil ? settings.admitted(to: thread) : settings
                let threadID = thread.id
                guard !isClosed else { return }
                await drafts.bind(submission.draft, to: threadID)
                guard !isClosed else { return }

                let session = await conversations.session(conversationID: conversationID, threadID: threadID)
                resolvedSessionID = threadID
                if sessionID == nil {
                    host.turnsChanged(turns.lockThread(threadID))
                }
                await host.threadStarted(thread, session: session, settingsRevision: settings.selectionRevision,
                                         requestedServiceTier: settings.serviceTier, admittedSettings: sessionID == nil ? settings : nil)
                await sessionIndex.record(sessionID: threadID, conversationID: conversationID)
                guard !isClosed else { return }
                dispatchAttempted = true
                let turnID = try await gateway.startTurn(
                    threadID: threadID,
                    clientUserMessageID: userMessageID.uuidString,
                    input: submission.input,
                    model: settings.model.id,
                    cyberAccessProgram: settings.model.automaticCyberAccessProgram,
                    effort: settings.reasoning.effort?.rawValue,
                    cwd: cwd,
                    serviceTier: settings.serviceTier,
                    additionalContext: submission.interactionMode.additionalContext
                )

                if !turns.hasCompleted(threadID: threadID, turnID: turnID) {
                    let jobID = GatewayNotificationRouting.jobID(threadID: threadID, turnID: turnID)
                    host.turnsChanged(turns.acceptDispatch(
                        ActiveJob(id: jobID, threadID: threadID),
                        turn: TrackedTurn(threadID: threadID, turnID: turnID, jobID: jobID),
                        conversationID: conversationID
                    ))
                    host.synchronizeConversationActivity()
                }

                await session.accepted(userMessageID, turnID: turnID)
                logger.notice("turn accepted thread=\(threadID) new=\(sessionID == nil) elapsed=\(String(describing: started.duration(to: .now)))")
                if sessionID == nil, host.selectionIsCurrent(revision: settings.selectionRevision, threadID: threadID) {
                    await metadata.upsert(sessionID: threadID, modelID: settings.model.id,
                        reasoningSelectionID: settings.reasoning.id,
                        fastModeEnabled: settings.fastModeState.remembered,
                        source: .selection)
                }
            } catch is CancellationError {
                let session = await conversations.session(conversationID: conversationID, threadID: resolvedSessionID ?? sessionID)
                await session.submissionFailed(userMessageID, failure: dispatchAttempted ? .uncertain("Sending was interrupted") : .notDispatched)
            } catch {
                feedback(.error)
                let session = await conversations.session(conversationID: conversationID, threadID: resolvedSessionID ?? sessionID)
                let failure = dispatchAttempted ? Self.inputDeliveryFailure(error) : .rejected(error.localizedDescription)
                await session.submissionFailed(userMessageID, failure: failure)
                if case .uncertain = failure, let threadID = resolvedSessionID {
                    await host.reconcileInputDelivery(threadID: threadID)
                    guard !isClosed, await session.deliveryIsUncertain(userMessageID) else { return }
                }
                await appendLocalReply("⛔️ \(failure.userMessage)", conversationID: conversationID,
                                       sessionID: resolvedSessionID ?? sessionID)
                if host.isVisibleConversation(conversationID, sessionID: resolvedSessionID ?? sessionID) {
                    host.speakIfOwningAudio("Error: \(failure.userMessage)")
                }
            }
        }
    }

    private func lock(conversationID: UUID, sessionID: String?) {
        host?.turnsChanged(turns.lock(conversationID: conversationID, threadID: sessionID))
    }

    private func unlock(conversationID: UUID, sessionID: String?) {
        host?.turnsChanged(turns.unlock(conversationID: conversationID, threadID: sessionID))
    }

    private func appendLocalReply(_ text: String, conversationID: UUID, sessionID: String?) async {
        let session = await conversations.session(conversationID: conversationID, threadID: sessionID)
        await session.appendLocal(ChatMessage(role: .codex, text: text))
    }

    private static func inputDeliveryFailure(_ error: Error) -> ConversationState.SubmissionFailure {
        if let failure = error as? GatewayRPCFailure {
            switch failure.kind {
            case .queueChangeUncertain, .inputDeliveryUncertain:
                return .uncertain(failure.localizedDescription)
            default:
                return .rejected(failure.localizedDescription)
            }
        }
        if case GatewayClient.ClientError.serverError = error { return .rejected(error.localizedDescription) }
        return .uncertain(error.localizedDescription)
    }

    private static func stopFailureMessage(_ error: Error) -> String {
        switch error {
        case let failure as GatewayRPCFailure:
            "Couldn't stop the agent: \(failure.message)"
        case GatewayClient.ClientError.serverError(let message, _):
            "Couldn't stop the agent: \(message)"
        case GatewayClient.ClientError.requestTimedOut:
            "The gateway didn't confirm the Stop, so the agent may still be running."
        case GatewayClient.ClientError.notConnected, GatewayClient.ClientError.connectionClosed,
             GatewayClient.ClientError.connectionFailed, GatewayClient.ClientError.gatewayRestarting:
            "Couldn't reach the gateway, so the agent may still be running."
        default:
            "Couldn't stop the agent: \(error.localizedDescription)"
        }
    }
}
