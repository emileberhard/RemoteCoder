import Foundation
import Synchronization

/// All transcript mutations are synchronous value operations, owned by ConversationSession.
struct ConversationState: Sendable {
    struct Item: Codable, Sendable, Equatable {
        var value: CodexAppServerV2.ThreadItem
        var position: Int64?
        var date: Date?
        var completedAtMs: Int64?
        var completed: Bool
        var detailed: Bool
        var isLocal = false
        var localMessage: ChatMessage?
        var activity: JobTimelineEvent?
        var observedLive = false
        var encodedBytes = 0
        var hasStreamingPrefix = false

        private enum CodingKeys: String, CodingKey {
            case value, position, date, completedAtMs, completed, detailed, isLocal, localMessage, activity, observedLive, encodedBytes
        }
    }

    struct Turn: Codable, Sendable, Equatable {
        let id: String
        var order: [String] = []
        var items: [String: Item] = [:]
        var startedAt: Date?
        var completedAt: Date?
        var isActive = false
        var terminal = false
        var terminalStatus: CodexAppServerV2.TurnStatus?
        var terminalError: String?
        var completionObservedLive: Bool?
        var hasDiscardedLiveItems = false

        var reportsOutcome: Bool {
            guard terminal, !isActive else { return false }
            return terminalStatus == .failed || (terminalStatus == .completed && completionObservedLive == true)
        }
    }

    struct TurnTable: Sendable {
        private struct Entry: Sendable {
            let turn: Turn
            let stamp: UInt64
        }
        private var entries: [String: Entry] = [:]
        private(set) var membershipStamp: UInt64 = 0

        subscript(id: String) -> Turn? {
            get { entries[id]?.turn }
            set {
                guard let newValue else { removeValue(forKey: id); return }
                if entries.updateValue(Entry(turn: newValue, stamp: ConversationState.nextStamp()), forKey: id) == nil {
                    membershipStamp = ConversationState.nextStamp()
                }
            }
        }

        var keys: some Collection<String> { entries.keys }
        var values: some Collection<Turn> { entries.values.lazy.map(\.turn) }
        var dictionary: [String: Turn] { entries.mapValues(\.turn) }

        func stamp(of id: String) -> UInt64? { entries[id]?.stamp }

        mutating func storeIfChanged(_ turn: Turn) {
            guard entries[turn.id]?.turn != turn else { return }
            self[turn.id] = turn
        }

        mutating func invalidate(_ id: String) {
            guard let turn = entries[id]?.turn else { return }
            entries[id] = Entry(turn: turn, stamp: ConversationState.nextStamp())
        }

        mutating func removeValue(forKey id: String) {
            guard entries.removeValue(forKey: id) != nil else { return }
            membershipStamp = ConversationState.nextStamp()
        }
    }

    private static let stampClock = Atomic<UInt64>(0)
    private static func nextStamp() -> UInt64 { stampClock.wrappingAdd(1, ordering: .relaxed).newValue }

    struct Submission: Codable, Sendable {
        enum Status: String, Codable, Hashable, Sendable { case submitting, accepted, queued, confirmed, uncertain, failed }
        struct Queue: Codable, Sendable, Equatable {
            var submissionID: String?
            var establishedRead: UInt64 = 0
            private enum CodingKeys: String, CodingKey { case submissionID }
        }
        var message: ChatMessage
        var input: String
        var turnID: String
        var status: Status = .submitting
        var queue: Queue?
        var questionEntries: [QuestionReplyEnvelope.Entry]?
        var questionEpoch: String?
        var canonicalQuestionOrdinal: Int64?
        var deliveryError: String?
    }

    struct Checkpoint: Codable, Sendable {
        let revision: UInt64
        let threadID: String?
        let order: [String]
        let turns: [String: Turn]
        let submissions: [UUID: Submission]
        let historyWindow: HistoryWindow?
        var tokenUsage: TokenUsageRecord?
        var questions: QuestionInventory?
        var questionDismissals: [String: QuestionDismissal]?
        var persistenceRevision: UInt64?
        var lastTurnCompletedAt: Int64?
        var turnStamps: [String: UInt64] = [:]
        var historyStamp: UInt64?
        var accountImports: Set<UUID>?

        private enum CodingKeys: String, CodingKey {
            case revision, threadID, order, turns, submissions, historyWindow, tokenUsage, questions
            case questionDismissals, persistenceRevision, lastTurnCompletedAt, accountImports
        }

        var durableRevision: UInt64 { persistenceRevision ?? revision }

        var containsLocalRecords: Bool {
            questionDismissals?.isEmpty == false || !submissions.isEmpty || turns.values.contains { $0.items.values.contains { $0.isLocal || $0.localMessage != nil } }
        }

        var localRecords: Checkpoint {
            let localTurns = turns.compactMapValues { turn -> Turn? in
                var local = turn
                local.items = turn.items.filter { $0.value.isLocal || $0.value.localMessage != nil }
                guard !local.items.isEmpty else { return nil }
                local.order = turn.order.filter { local.items[$0] != nil }
                for (id, var item) in local.items where !item.isLocal {
                    if case .userMessage(_, _, let clientID) = item.value {
                        item.value = .userMessage(id: id, content: [], clientId: clientID)
                        item.detailed = false
                        item.encodedBytes = 0
                        local.items[id] = item
                    }
                }
                return local
            }
            return Checkpoint(revision: revision, threadID: threadID, order: order.filter { localTurns[$0] != nil },
                turns: localTurns, submissions: submissions, historyWindow: nil, tokenUsage: nil, questions: nil,
                questionDismissals: questionDismissals, persistenceRevision: persistenceRevision, lastTurnCompletedAt: nil, accountImports: accountImports)
        }

        struct SettledImage {
            let messageID: UUID
            let attachmentID: UUID
            let date: Date
        }

        var settledImages: [SettledImage] {
            turns.values.flatMap { $0.items.values }.flatMap { item -> [SettledImage] in
                guard !item.isLocal, let message = item.localMessage,
                      submissions[message.id] == nil || submissions[message.id]?.status == .confirmed else { return [] }
                return message.attachments.compactMap {
                    guard case .imageData = $0.content else { return nil }
                    return SettledImage(messageID: message.id, attachmentID: $0.id, date: message.date)
                }
            }
        }

        var unavailableImages: [UUID: Set<UUID>] {
            var result: [UUID: Set<UUID>] = [:]
            for item in turns.values.flatMap({ $0.items.values }) {
                guard let message = item.localMessage else { continue }
                for attachment in message.attachments {
                    if case .unavailableImage = attachment.content { result[message.id, default: []].insert(attachment.id) }
                }
            }
            return result
        }

        func applyingUnavailableImages(_ images: [UUID: Set<UUID>]) -> Checkpoint {
            guard !images.isEmpty else { return self }
            var updatedTurns = turns
            var updatedSubmissions = submissions
            var stamps = turnStamps
            for (turnID, var turn) in turns {
                for (itemID, var item) in turn.items {
                    guard !item.isLocal, var message = item.localMessage, let removed = images[message.id],
                          submissions[message.id] == nil || submissions[message.id]?.status == .confirmed else { continue }
                    message.attachments = message.attachments.map {
                        guard removed.contains($0.id), case .imageData = $0.content else { return $0 }
                        return MessageAttachment(id: $0.id, content: .unavailableImage)
                    }
                    item.localMessage = message
                    item.detailed = false
                    turn.items[itemID] = item
                    if updatedSubmissions[message.id]?.status == .confirmed { updatedSubmissions[message.id]?.message = message }
                }
                if turn != turns[turnID] {
                    updatedTurns[turnID] = turn
                    stamps.removeValue(forKey: turnID)
                }
            }
            var result = Checkpoint(revision: revision, threadID: threadID, order: order, turns: updatedTurns,
                submissions: updatedSubmissions, historyWindow: historyWindow, tokenUsage: tokenUsage, questions: questions,
                questionDismissals: questionDismissals, persistenceRevision: persistenceRevision, lastTurnCompletedAt: lastTurnCompletedAt, accountImports: accountImports)
            result.turnStamps = stamps
            result.historyStamp = historyStamp
            return result
        }
    }

    mutating func applyUnavailableImages(_ images: [UUID: Set<UUID>]) {
        guard !images.isEmpty else { return }
        let updated = checkpoint.applyingUnavailableImages(images)
        var changed = false
        for (id, turn) in updated.turns where turns[id] != turn {
            turns.storeIfChanged(turn)
            changed = true
        }
        for (id, submission) in updated.submissions { submissions[id]?.message = submission.message }
        if changed { revision += 1 }
    }

    struct TokenUsageRecord: Codable, Sendable {
        let turnID: String
        let usage: CodexAppServerV2.ThreadTokenUsage
    }

    struct HistoryRead: Sendable {
        let owner: UUID
        let order: UInt64
        let base: HistoryWindow?
    }

    struct QueueRead: Sendable {
        let owner: UUID
        let order: UInt64
    }

    private struct WindowCoverage: Equatable, Sendable {
        struct Turn: Equatable, Sendable {
            let id: String
            let entries: [String]
            let latest: Int64?
        }

        let reachesTail: Bool
        let turns: [Turn]

        init?(_ window: HistoryWindow?) {
            guard let window, window.isLoaded else { return nil }
            reachesTail = window.newer == nil
            turns = window.turns.map { turn in
                Turn(id: turn.id, entries: turn.entries.map(\.id), latest: turn.entries.compactMap(\.startedAtOrdinal).max())
            }
        }
    }

    let conversationID: UUID
    let ownerID: UUID
    var threadID: String?
    var revision: UInt64 = 0
    private(set) var persistenceRevision: UInt64 = 0
    private var hasLiveChanges = false
    var order: [String] = []
    var turns = TurnTable()
    var submissions: [UUID: Submission] = [:]
    var window: HistoryWindow? {
        didSet {
            historyPersistenceStamp = Self.nextStamp()
            let coverage = WindowCoverage(window)
            guard coverage != windowCoverage else { return }
            defer { windowCoverage = coverage }
            guard let coverage, let previous = windowCoverage, coverage.reachesTail == previous.reachesTail,
                  coverage.turns.last?.id == previous.turns.last?.id else {
                windowStamp = Self.nextStamp()
                return
            }
            var before = Dictionary(uniqueKeysWithValues: previous.turns.map { ($0.id, $0) })
            for turn in coverage.turns where before.removeValue(forKey: turn.id) != turn { turns.invalidate(resolvedTurnID(turn.id)) }
            for id in before.keys { turns.invalidate(resolvedTurnID(id)) }
        }
    }
    private var accountImports: Set<UUID> = []
    private var windowCoverage: WindowCoverage?
    private var historyPersistenceStamp: UInt64 = 0
    private(set) var windowStamp: UInt64 = 0
    private(set) var tokenUsage: TokenUsageRecord?
    private var hasVerifiedTail = false
    private var startedHistoryReads: UInt64 = 0
    private var appliedTailRead: UInt64 = 0
    private var startedQueueReads: UInt64 = 0
    private var appliedQueueRead: UInt64 = 0
    var questions: QuestionInventory?
    var questionDismissals: [String: QuestionDismissal]?
    private(set) var lastTurnCompletedAt: Int64?
    // Expansion follows canonical activity through newly discovered message boundaries.
    var expandedTimelineAnchors: Set<String> = []
    private var replaySequences: Set<UInt64> = []
    private var replaySequenceOrder: [UInt64] = []
    var latestNotificationSequence: UInt64? { replaySequenceOrder.max() }
    var compaction: ConversationCompaction?
    var compactionBaselineTurns: Set<String> = []
    var compactionSequence: UInt64?

    init(conversationID: UUID, threadID: String? = nil, ownerID: UUID = UUID()) {
        self.conversationID = conversationID
        self.threadID = threadID
        self.ownerID = ownerID
    }

    mutating func restore(_ checkpoint: Checkpoint, live: Bool = false) {
        accountImports.formUnion(checkpoint.accountImports ?? [])
        let mergesChanges = persistenceRevision > 0 || live
        // A restore may finish after live events. Merge missing facts, never replace live state.
        let reconciled = Set(checkpoint.submissions.keys.filter { contains(clientID: $0) }.map(\.uuidString))
        order = Self.mergeOrder(existing: order, observed: checkpoint.order)
        for (id, saved) in checkpoint.turns {
            var turn = turns[id] ?? Turn(id: id)
            turn.order = Self.mergeOrder(existing: turn.order, observed: saved.order)
            for (itemID, savedItem) in saved.items where turn.items[itemID] == nil && !reconciled.contains(itemID) {
                var item = savedItem
                if !live { item.hasStreamingPrefix = false }
                turn.items[itemID] = item
            }
            turn.order.removeAll { turn.items[$0] == nil }
            turn.startedAt = turn.startedAt ?? saved.startedAt
            turn.completedAt = turn.completedAt ?? saved.completedAt
            if turns[id] == nil {
                turn.terminal = saved.terminal; turn.terminalStatus = saved.terminalStatus; turn.isActive = live && saved.isActive
                turn.terminalError = saved.terminalError; turn.completionObservedLive = saved.completionObservedLive
            }
            turns.storeIfChanged(turn)
        }
        for (id, submission) in checkpoint.submissions where !contains(clientID: id) {
            if submissions[id] == nil {
                var restored = submission
                if restored.status == .submitting || restored.status == .queued && !live { restored.status = .uncertain }
                submissions[id] = restored
            }
        }
        if window == nil { window = checkpoint.historyWindow }
        if tokenUsage == nil { tokenUsage = checkpoint.tokenUsage }
        recordTurnCompletion(at: checkpoint.lastTurnCompletedAt)
        if questionDismissals == nil { questionDismissals = checkpoint.questionDismissals }
        if questions == nil, var saved = checkpoint.questions {
            saved.invalidate("Refresh question state after reopening")
            questions = saved
        }
        for id in order where turns[id]?.order.isEmpty == true && turns[id]?.isActive != true && turns[id]?.reportsOutcome != true {
            turns.removeValue(forKey: id)
        }
        order.removeAll { turns[$0] == nil }
        revision = max(revision, checkpoint.revision) + 1
        persistenceRevision = max(persistenceRevision, checkpoint.durableRevision) + (mergesChanges ? 1 : 0)
    }

    var checkpoint: Checkpoint {
        var checkpoint = Checkpoint(revision: revision, threadID: threadID, order: order, turns: turns.dictionary,
                   submissions: submissions, historyWindow: window, tokenUsage: tokenUsage,
                   questions: questions, questionDismissals: questionDismissals,
                   persistenceRevision: persistenceRevision, lastTurnCompletedAt: lastTurnCompletedAt,
                   accountImports: accountImports.isEmpty ? nil : accountImports)
        checkpoint.turnStamps = Dictionary(uniqueKeysWithValues: turns.keys.compactMap { id in turns.stamp(of: id).map { (id, $0) } })
        checkpoint.historyStamp = historyPersistenceStamp
        return checkpoint
    }

    mutating func markPersistedChange() {
        revision += 1
        persistenceRevision += 1
        hasLiveChanges = false
    }

    mutating func commitLiveChanges() {
        guard hasLiveChanges else { return }
        persistenceRevision += 1
        hasLiveChanges = false
    }

    private mutating func markLiveChange() {
        revision += 1
        hasLiveChanges = true
    }

    private static let liveOnlyMethods: Set<String> = [
        "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/plan/delta",
        "turn/plan/updated", "turn/diff/updated",
    ]

    mutating func submit(_ message: ChatMessage, input: String? = nil) {
        clearFinishedCompaction()
        let turnID = message.canonicalTurnID.map(resolvedTurnID) ?? Self.localTurnID(message.id)
        submissions[message.id] = Submission(message: message, input: input ?? message.text, turnID: turnID,
            questionEntries: message.questionReplies == nil ? nil : QuestionReplyEnvelope.parse(input ?? message.text),
            questionEpoch: message.questionReplies == nil ? nil : questions?.epoch)
        var turn = ensureTurn(turnID)
        let id = message.id.uuidString
        // The canonical content is what the agent receives; the local message keeps the display text.
        turn.items[id] = Item(value: .userMessage(id: id, content: [.text(text: input ?? message.text, textElements: [])], clientId: id),
                              date: message.date, completed: false, detailed: true, isLocal: true, localMessage: message)
        if !turn.order.contains(id) { turn.order.append(id) }
        turns[turnID] = turn
        markPersistedChange()
    }

    mutating func submitToQueue(_ message: ChatMessage, input: String) {
        submit(message, input: input)
        submissions[message.id]?.queue = Submission.Queue()
    }

    mutating func queued(_ messageID: UUID, submission: CodexAppServerV2.QueuedSubmission) {
        guard var pending = submissions[messageID], pending.queue != nil,
              submission.clientUserMessageId == messageID.uuidString,
              pending.status == .submitting || pending.status == .uncertain || pending.status == .queued else { return }
        pending.status = .queued
        pending.queue = Submission.Queue(submissionID: submission.id, establishedRead: startedQueueReads)
        pending.deliveryError = nil
        submissions[messageID] = pending
        markPersistedChange()
    }

    mutating func queueRemoved(_ messageID: UUID) {
        guard let pending = submissions[messageID], pending.queue != nil, pending.status == .queued else { return }
        submissions.removeValue(forKey: messageID)
        let id = messageID.uuidString
        turns[pending.turnID]?.items.removeValue(forKey: id)
        turns[pending.turnID]?.order.removeAll { $0 == id }
        if Self.isLocalTurnID(pending.turnID), turns[pending.turnID]?.order.isEmpty == true {
            turns.removeValue(forKey: pending.turnID)
            order.removeAll { $0 == pending.turnID }
        }
        markPersistedChange()
    }

    func queuedSubmissionID(for messageID: UUID) -> String? {
        guard let pending = submissions[messageID], pending.status == .queued else { return nil }
        return pending.queue?.submissionID
    }

    var hasQueueReceipts: Bool {
        submissions.values.contains { $0.queue != nil && ($0.status == .queued || $0.status == .uncertain) }
    }

    mutating func beginQueueRead() -> QueueRead {
        startedQueueReads += 1
        return QueueRead(owner: ownerID, order: startedQueueReads)
    }

    mutating func applyQueue(_ entries: [CodexAppServerV2.QueuedSubmission], read: QueueRead, threadIsIdle: Bool) {
        guard read.owner == ownerID, read.order > appliedQueueRead else { return }
        appliedQueueRead = read.order
        let listed = Dictionary(entries.map { ($0.clientUserMessageId, $0.id) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for (id, pending) in submissions where pending.queue != nil {
            if let submissionID = listed[id.uuidString] {
                guard pending.status == .submitting || pending.status == .uncertain || pending.status == .queued,
                      pending.status != .queued || pending.queue?.submissionID != submissionID else { continue }
                submissions[id]?.status = .queued
                submissions[id]?.queue = Submission.Queue(submissionID: submissionID, establishedRead: read.order)
                submissions[id]?.deliveryError = nil
                changed = true
            } else if threadIsIdle, pending.status == .queued, let queue = pending.queue, queue.establishedRead < read.order {
                submissions[id]?.status = .uncertain
                submissions[id]?.deliveryError = "The queue no longer lists this message."
                changed = true
            }
        }
        if changed { markPersistedChange() }
    }

    mutating func accepted(_ messageID: UUID, turnID: String) {
        guard var pending = submissions[messageID], pending.status != .confirmed else { return }
        let turnID = resolvedTurnID(turnID)
        let id = messageID.uuidString
        let oldTurnID = pending.turnID
        let oldIndex = turns[oldTurnID]?.order.firstIndex(of: id)
        let item = turns[oldTurnID]?.items.removeValue(forKey: id)
        turns[oldTurnID]?.order.removeAll { $0 == id }
        pending.turnID = turnID
        if let previous = pending.message.canonicalTurnID, previous != turnID { pending.message.wasSteered = false }
        pending.message.canonicalTurnID = turnID
        pending.status = .accepted
        submissions[messageID] = pending
        var turn = ensureTurn(turnID)
        if var item {
            item.localMessage = pending.message
            turn.items[id] = item
            if !turn.order.contains(id) {
                let index = oldTurnID == turnID ? (oldIndex ?? turn.order.count) : (pending.message.wasSteered ? turn.order.count : 0)
                turn.order.insert(id, at: min(index, turn.order.count))
            }
        }
        turns[turnID] = turn
        if oldTurnID != turnID, turns[oldTurnID]?.order.isEmpty == true {
            turns.removeValue(forKey: oldTurnID)
            order.removeAll { $0 == oldTurnID }
        }
        markPersistedChange()
    }

    enum SubmissionFailure: Sendable {
        case notDispatched
        case rejected(String)
        case uncertain(String)

        var userMessage: String {
            switch self {
            case .notDispatched: "The message wasn't sent. Try again."
            case .rejected(let reason): reason
            case .uncertain: "Delivery wasn't confirmed. The message may have arrived. Check the conversation before sending again."
            }
        }
    }

    mutating func submissionFailed(_ messageID: UUID, failure: SubmissionFailure) {
        guard let pending = submissions[messageID], pending.status != .accepted, pending.status != .confirmed,
              pending.status != .queued else { return }
        switch failure {
        case .notDispatched:
            submissions[messageID]?.status = .failed
            submissions[messageID]?.deliveryError = "The operation stopped before sending."
        case .rejected(let reason):
            submissions[messageID]?.status = .failed
            submissions[messageID]?.deliveryError = reason
        case .uncertain(let reason):
            submissions[messageID]?.status = .uncertain
            submissions[messageID]?.deliveryError = reason
        }
        markPersistedChange()
    }

    mutating func submissionNotDispatched(_ messageID: UUID) {
        guard let pending = submissions.removeValue(forKey: messageID) else { return }
        let id = messageID.uuidString
        turns[pending.turnID]?.items.removeValue(forKey: id)
        turns[pending.turnID]?.order.removeAll { $0 == id }
        markPersistedChange()
    }

    mutating func takeDiscardedSteers(of turnID: String) -> Submission? {
        let turnID = resolvedTurnID(turnID)
        let steers = turns[turnID]?.order.compactMap { UUID(uuidString: $0).flatMap { submissions[$0] } }
            .filter { $0.message.wasSteered && $0.status == .accepted && $0.turnID == turnID } ?? []
        guard steers.count > 1 else { return steers.first }
        let message = ChatMessage(role: .user, text: steers.map(\.message.text).joined(separator: "\n"),
                                  attachments: steers.flatMap(\.message.attachments))
        for steer in steers { submissionNotDispatched(steer.message.id) }
        submit(message, input: steers.map(\.input).joined(separator: "\n"))
        return submissions[message.id]
    }

    mutating func appendLocal(_ message: ChatMessage, turnID: String?) {
        let id = turnID.map(resolvedTurnID) ?? Self.localTurnID(message.id)
        var turn = ensureTurn(id)
        let itemID = message.id.uuidString
        turn.items[itemID] = Item(value: .agentMessage(id: itemID, text: message.text), date: message.date,
                                  completed: true, detailed: true, isLocal: true, localMessage: message)
        if !turn.order.contains(itemID) { turn.order.append(itemID) }
        turns[id] = turn
        markPersistedChange()
    }

    mutating func activity(turnID: String, active: Bool) {
        let turnID = resolvedTurnID(turnID)
        guard turns[turnID]?.isActive != active, turns[turnID] != nil || active else { return }
        var turn = ensureTurn(turnID)
        turn.isActive = active
        turns[turnID] = turn
        markPersistedChange()
    }

    private mutating func recordTurnCompletion(header: Int64?, observed turns: [CodexAppServerV2.Turn]) {
        recordTurnCompletion(at: header)
        guard threadID?.hasPrefix("claude_") == false else { return }
        recordTurnCompletion(at: turns.lazy.compactMap(\.completedAt).max())
    }

    private mutating func recordTurnCompletion(at completedAt: Int64?) {
        guard let completedAt, completedAt > lastTurnCompletedAt ?? .min else { return }
        lastTurnCompletedAt = completedAt
    }

    mutating func resetEventSequences() {
        replaySequences.removeAll()
        replaySequenceOrder.removeAll()
        compactionSequence = nil
    }

    mutating func revokeStreamingPrefixes() {
        for id in order {
            guard var turn = turns[id] else { continue }
            let items = turn.order.filter { turn.items[$0]?.completed == false && turn.items[$0]?.hasStreamingPrefix == true }
            guard !items.isEmpty else { continue }
            for item in items { turn.items[item]?.hasStreamingPrefix = false }
            turns[id] = turn
        }
    }

    mutating func apply(_ event: TurnScopedGatewayEvent, replay: Bool = false) {
        guard event.threadID == threadID else { return }
        if let sequence = event.note.sequence {
            guard replaySequences.insert(sequence).inserted else { return }
            replaySequenceOrder.append(sequence)
            if replaySequenceOrder.count > 4096 { replaySequences.remove(replaySequenceOrder.removeFirst()) }
        }
        let turnID = resolvedTurnID(event.turnID)
        observeCompaction(event, replay: replay, turnID: turnID)
        let knownTurnCount = order.count
        var turn = ensureTurn(turnID)
        let knownItemCount = turn.order.count
        let observed = event.note.receivedAt ?? .now
        switch event.note.server {
        case .turnStarted:
            turn.startedAt = turn.startedAt ?? observed
            if turn.terminalStatus != .completed && turn.terminalStatus != .failed, !replay || !turn.terminal {
                turn.isActive = true; turn.terminal = false; turn.terminalStatus = nil; turn.terminalError = nil
                turn.completionObservedLive = nil; turn.completedAt = nil
            }
        case .turnCompleted(let completion):
            turn.isActive = false
            turn.terminal = true
            turn.terminalStatus = completion.status
            turn.terminalError = completion.errorMessage
            turn.completionObservedLive = true
            turn.completedAt = turn.completedAt ?? observed
            recordTurnCompletion(at: completion.completedAt)
        case .itemStarted(let itemEvent), .itemCompleted(let itemEvent):
            let value = itemEvent.item
            let complete = event.method == "item/completed"
            let date = itemEvent.startedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? (complete ? nil : observed)
            let position = itemEvent.startedAtOrdinal
            let completedAt = complete ? itemEvent.completedAtMs : nil
            let previous = turn.items[value.id]
            if complete, replay, previous?.completed == true {
                guard let completedAt else { return }
                if let previousCompletion = previous?.completedAtMs, completedAt <= previousCompletion { return }
            }
            if !complete, previous?.detailed == true {
                if !replay, previous?.completed == false, previous?.hasStreamingPrefix == false {
                    turn.items[value.id]?.value = value
                    turn.items[value.id]?.hasStreamingPrefix = true
                    turn.items[value.id]?.observedLive = true
                    turn.items[value.id]?.encodedBytes = itemEvent.encodedBytes
                }
                turn.items[value.id]?.position = position ?? previous?.position
                turn.items[value.id]?.date = previous?.date ?? date
                turns[turnID] = turn
                markPersistedChange()
                trim()
                return
            }
            if previous?.completed != true || complete {
                var item = Item(value: value, position: position ?? previous?.position, date: previous?.date ?? date, completedAtMs: completedAt,
                                completed: complete, detailed: true, localMessage: previous?.localMessage)
                item.observedLive = true
                item.hasStreamingPrefix = !complete && !replay
                item.encodedBytes = itemEvent.encodedBytes
                reconcile(&item, in: &turn)
                turn.items[value.id] = item
                if !turn.order.contains(value.id) { turn.order.append(value.id) }
            }
        case .agentMessageDelta(let delta):
            guard !delta.delta.isEmpty else { return }
            // Replayed deltas have no identity shared with the unsequenced live stream.
            // Completed item snapshots/history reconcile them without double-appending text.
            guard !replay else { return }
            guard var item = turn.items[delta.itemID], !item.completed, item.hasStreamingPrefix else { return }
            if case .agentMessage(let id, let text, let phase, let delivery, let questions) = item.value {
                item.value = .agentMessage(id: id, text: text + delta.delta, phase: phase, delivery: delivery, questions: questions)
            }
            item.observedLive = true
            item.encodedBytes += delta.delta.utf8.count
            turn.items[delta.itemID] = item
            if !turn.order.contains(delta.itemID) { turn.order.append(delta.itemID) }
        case .reasoningSummaryDelta(let update), .reasoningTextDelta(let update), .planDelta(let update):
            let id = update.itemID
            let delta = update.delta
            guard !replay, var item = turn.items[id], !item.completed, item.hasStreamingPrefix else { return }
            switch item.value {
            case .plan(let id, let text): item.value = .plan(id: id, text: text + delta)
            case .reasoning(let id, var summary, var content):
                let summaryDelta = event.method.contains("summary")
                let index = max(0, update.index ?? 0)
                guard index < 200 else { return }
                if summaryDelta {
                    while summary.count <= index { summary.append("") }
                    summary[index] += delta
                } else {
                    while content.count <= index { content.append("") }
                    content[index] += delta
                }
                item.value = .reasoning(id: id, summary: summary, content: content)
            default: return
            }
            item.observedLive = true
            item.encodedBytes += delta.utf8.count
            turn.items[id] = item
        case .turnPlanUpdated(let update), .turnDiffUpdated(let update):
            let id = event.method
            let text = update.text
            guard !text.isEmpty else { return }
            turn.items[id] = Item(value: .plan(id: id, text: text), date: observed, completed: false, detailed: true)
            if !turn.order.contains(id) { turn.order.append(id) }
        default: return
        }
        turns[turnID] = turn
        if Self.liveOnlyMethods.contains(event.method) {
            markLiveChange()
            if order.count != knownTurnCount { trim() }
            else if turn.order.count != knownItemCount { trimLiveItems(turnID: turnID) }
        } else {
            markPersistedChange()
            trim()
        }
    }

    mutating func beginHistoryRead() -> HistoryRead {
        startedHistoryReads += 1
        return HistoryRead(owner: ownerID, order: startedHistoryReads, base: window)
    }

    mutating func merge(_ snapshot: GatewayHistoryService.ConversationSnapshot, read: HistoryRead) {
        guard snapshot.header.id == threadID else { return }
        rememberExpandedActivity()
        let applied = snapshot.source == .storedTail
            ? adoptStoredTail(snapshot.window)
            : adopt(snapshot.update, resulting: snapshot.window, read: read)
        recordTurnCompletion(header: snapshot.header.lastTurnCompletedAt, observed: window?.turns.compactMap(\.metadata) ?? [])
        let rereadsTail = applied && snapshot.update?.placement.readsTail == true
        if rereadsTail || applied && snapshot.source == .storedTail { hasVerifiedTail = snapshot.source == .gateway }
        if applied, let window { mergeHistory(window, rereadsTail: rereadsTail) }
        if applied, snapshot.source == .gateway { reconcileCompactionFromHistory() }
        markPersistedChange()
        trim()
    }

    @discardableResult
    mutating func reconcileDeliveryEvidence(_ snapshot: GatewayHistoryService.ConversationSnapshot) -> Bool {
        guard snapshot.header.id == threadID, snapshot.source == .gateway else { return false }
        var changed = false
        for observed in snapshot.window.turns {
            for entry in observed.entries {
                guard case .userMessage(_, _, let rawClientID) = entry.item,
                      let rawClientID, let clientID = UUID(uuidString: rawClientID),
                      let pending = submissions[clientID], pending.status != .confirmed, pending.status != .failed else { continue }
                let turnID = resolvedTurnID(observed.id)
                var turn = ensureTurn(turnID)
                let index = turn.order.firstIndex(of: clientID.uuidString) ?? turn.order.count
                var item = Item(value: entry.item, position: entry.startedAtOrdinal,
                    date: turn.items[entry.item.id]?.date ?? pending.message.date,
                    completedAtMs: entry.completedAtMs, completed: entry.isComplete ?? true, detailed: true)
                item.encodedBytes = (try? JSONEncoder().encode(entry.item).count) ?? 0
                reconcile(&item, in: &turn)
                turn.items[entry.item.id] = item
                if !turn.order.contains(entry.item.id) { turn.order.insert(entry.item.id, at: min(index, turn.order.count)) }
                turns[turnID] = turn
                trimLiveItems(turnID: turnID)
                changed = true
            }
        }
        if changed { markPersistedChange() }
        return changed
    }

    private mutating func adopt(_ update: HistoryWindow.Update?, resulting: HistoryWindow, read: HistoryRead) -> Bool {
        let readsTail = update?.placement.readsTail == true
        if readsTail {
            guard read.owner == ownerID, read.order > appliedTailRead else { return false }
        }
        if var current = window {
            guard let update, current.apply(update) else { return false }
            window = current
        } else {
            window = resulting
        }
        if readsTail { appliedTailRead = read.order }
        return true
    }

    private mutating func adoptStoredTail(_ stored: HistoryWindow) -> Bool {
        guard stored.isLoaded, stored.newer == nil, window?.isLoaded != true || window?.newer != nil else { return false }
        window = stored
        return true
    }

    private mutating func mergeHistory(_ window: HistoryWindow, rereadsTail: Bool) {
        // A history read can label a turn with an id the gateway never emitted
        // for a prompt its stream has not echoed yet. Adopting that label clones
        // items the live stream already placed, so an unknown label whose items
        // a known turn owns is that turn under a different name. Placeholder
        // turns are excluded: a submission still waiting for its real turn id
        // must adopt the observed one, not keep `local-`.
        var owners: [String: String] = [:]
        for id in order where !Self.isLocalTurnID(id) {
            guard let known = turns[id] else { continue }
            for item in known.items.keys where owners[item] == nil { owners[item] = id }
        }
        let identities = Dictionary(window.turns.map { observed -> (String, String) in
            let resolved = resolvedTurnID(observed.id)
            guard turns[resolved] == nil else { return (observed.id, resolved) }
            let owner = observed.entries.first { owners[$0.item.id] != nil }.flatMap { owners[$0.item.id] }
            return (observed.id, owner ?? resolved)
        }, uniquingKeysWith: { _, last in last })
        // An alias carries no position of its own when the turn it names was also
        // observed directly; letting the first occurrence win moved a live turn
        // ahead of the turns before it.
        let direct = Set(window.turns.map { resolvedTurnID($0.id) })
        let observedOrder = window.turns.compactMap { observed -> String? in
            let id = identities[observed.id] ?? observed.id
            return id != resolvedTurnID(observed.id) && direct.contains(id) ? nil : id
        }
        order = Self.mergeOrder(existing: order, observed: observedOrder)
        for observed in window.turns {
            var turn = ensureTurn(identities[observed.id] ?? resolvedTurnID(observed.id))
            if let metadata = observed.metadata {
                turn.startedAt = turn.startedAt ?? metadata.startedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                turn.completedAt = turn.completedAt ?? metadata.completedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                if metadata.status != .inProgress {
                    turn.terminal = true; turn.terminalStatus = metadata.status; turn.terminalError = metadata.error?.message
                }
            }
            if rereadsTail { turn.hasDiscardedLiveItems = false }
            for entry in observed.entries {
                let value = entry.item
                let previous = turn.items[value.id]
                let complete = entry.isComplete ?? true
                let newerCompletion = entry.completedAtMs.map { incoming in previous?.completedAtMs.map { incoming > $0 } ?? false } ?? false
                if previous?.completed == true && previous?.detailed == true && !newerCompletion {
                    turn.items[value.id]?.position = previous?.position ?? entry.startedAtOrdinal
                    continue
                }
                if previous?.completed == false && !complete { continue }
                let started = entry.startedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
                var item = Item(value: value, position: entry.startedAtOrdinal ?? previous?.position,
                                date: previous?.date ?? started ?? turn.startedAt,
                                completedAtMs: entry.completedAtMs,
                                completed: complete, detailed: true, localMessage: previous?.localMessage)
                item.observedLive = previous?.observedLive ?? false
                item.hasStreamingPrefix = previous?.hasStreamingPrefix ?? false
                reconcile(&item, in: &turn)
                if item.observedLive {
                    if let previous, previous.observedLive, previous.value == value {
                        item.encodedBytes = previous.encodedBytes
                    } else {
                        item.encodedBytes = (try? JSONEncoder().encode(value).count) ?? 0
                    }
                }
                turn.items[value.id] = item
            }
            turn.order = Self.mergeOrder(existing: turn.order, observed: observed.entries.map(\.item.id))
            turns.storeIfChanged(turn)
        }
    }

    mutating func mergeObservation(
        header: ConversationHeader,
        checkpoint: CodexAppServerV2.ThreadObservationCheckpoint,
        history: GatewayHistoryService.ObservationHistory,
        read: HistoryRead
    ) {
        guard header.id == threadID else { return }
        recordTurnCompletion(header: header.lastTurnCompletedAt, observed: history.turns)
        rememberExpandedActivity()
        if let update = history.update {
            var fresh = HistoryWindow()
            fresh.apply(update)
            if adopt(update, resulting: fresh, read: read) { hasVerifiedTail = true }
        }
        let metadata = (checkpoint.activeTurn.map { [$0] } ?? []) + (history.update?.metadata.flatMap(\.page.elements) ?? [])
        for observed in metadata + history.turns {
            var turn = ensureTurn(resolvedTurnID(observed.id))
            turn.startedAt = observed.startedAt.map { Date(timeIntervalSince1970: Double($0)) } ?? turn.startedAt
            if observed.status != .inProgress {
                turn.terminal = true
                turn.terminalStatus = observed.status
                turn.terminalError = observed.error?.message
                turn.isActive = false
                turn.completedAt = observed.completedAt.map { Date(timeIntervalSince1970: Double($0)) } ?? turn.completedAt
            }
            turns.storeIfChanged(turn)
        }
        order = Self.mergeOrder(existing: order, observed: history.turns.map { resolvedTurnID($0.id) })
        // Durable completion wins over listener prefixes when persistence is ahead.
        // Otherwise the listener prefix replaces the pre-ack local partial value.
        for (entry, isLive) in history.entries.map({ ($0, false) }) + checkpoint.liveItems.map({ ($0, true) }) {
            var turn = ensureTurn(resolvedTurnID(entry.turnId))
            if checkpoint.historyUnavailable { turn.hasDiscardedLiveItems = true }
            let previous = turn.items[entry.item.id]
            let complete = entry.isComplete == true
            if previous?.completed == true && !complete { continue }
            if !complete, !isLive, previous?.hasStreamingPrefix == true {
                turns.storeIfChanged(turn)
                continue
            }
            var item = Item(value: entry.item, position: entry.startedAtOrdinal ?? previous?.position,
                date: entry.startedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? previous?.date,
                completedAtMs: entry.completedAtMs, completed: complete, detailed: true,
                localMessage: previous?.localMessage)
            item.observedLive = true
            item.hasStreamingPrefix = !item.completed && isLive
            item.encodedBytes = (try? JSONEncoder().encode(entry.item).count) ?? 0
            reconcile(&item, in: &turn)
            turn.items[entry.item.id] = item
            if !turn.order.contains(entry.item.id) { turn.order.append(entry.item.id) }
            let positioned = turn.order.compactMap { id -> (id: String, position: Int64)? in
                guard let position = turn.items[id]?.position else { return nil }
                return (id, position)
            }.sorted { $0.position < $1.position }.map { $0.id }
            turn.order = Self.mergeOrder(existing: turn.order, observed: positioned)
            turns.storeIfChanged(turn)
        }
        markPersistedChange()
        trim()
    }

    private mutating func reconcile(_ item: inout Item, in turn: inout Turn) {
        guard case .userMessage(_, let content, let clientID) = item.value,
              let clientID, let id = UUID(uuidString: clientID) else { return }
        defer {
            item.localMessage?.useCanonicalImages(content)
            if submissions[id]?.status == .confirmed { submissions[id]?.message.useCanonicalImages(content) }
        }
        guard let pending = submissions.removeValue(forKey: id) else { return }
        item.localMessage = pending.message
        if pending.questionEntries != nil && !pending.questionIsConfirmed(by: questions) {
            var receipt = pending
            receipt.status = .confirmed
            receipt.canonicalQuestionOrdinal = item.position
            receipt.turnID = turn.id
            receipt.message.canonicalTurnID = turn.id
            submissions[id] = receipt
        }
        item.observedLive = true
        let localID = id.uuidString
        turn.items.removeValue(forKey: localID)
        turn.order.removeAll { $0 == localID }
        if pending.turnID != turn.id {
            turns[pending.turnID]?.items.removeValue(forKey: localID)
            turns[pending.turnID]?.order.removeAll { $0 == localID }
            if turns[pending.turnID]?.order.isEmpty == true {
                turns.removeValue(forKey: pending.turnID)
                order.removeAll { $0 == pending.turnID }
            }
        }
    }

    func contains(clientID: UUID) -> Bool {
        turns.values.contains { turn in
            turn.items.values.contains { item in
                if case .userMessage(_, _, let id) = item.value { return id.flatMap(UUID.init(uuidString:)) == clientID && !item.isLocal }
                return false
            }
        }
    }

    /// A turn that exists only on this device until the gateway names the real one.
    static func localTurnID(_ id: some CustomStringConvertible) -> String { "local-\(id)" }
    static func isLocalTurnID(_ id: String) -> Bool { id.hasPrefix("local-") }

    private func resolvedTurnID(_ raw: String) -> String {
        if turns[raw] != nil { return raw }
        let normalized = GatewayNotificationRouting.normalizeTurnID(raw)
        return order.first { GatewayNotificationRouting.normalizeTurnID($0) == normalized } ?? raw
    }

    private mutating func ensureTurn(_ id: String) -> Turn {
        if !order.contains(id) {
            let waiting = Self.isLocalTurnID(id) ? [] : Set(submissions.values.filter {
                $0.queue != nil && $0.status != .failed && Self.isLocalTurnID($0.turnID)
            }.map(\.turnID))
            let slot = waiting.isEmpty ? order.endIndex : (order.lastIndex { !waiting.contains($0) }.map { $0 + 1 } ?? 0)
            order.insert(id, at: slot)
        }
        return turns[id] ?? Turn(id: id)
    }

    /// Observation order is authoritative for common IDs; absent local/live facts retain their neighbors.
    static func mergeOrder(existing: [String], observed: [String]) -> [String] {
        var unique = Set<String>()
        var result = observed.filter { unique.insert($0).inserted }
        var present = Set(result)
        for (index, id) in existing.enumerated() where !present.contains(id) {
            let following = Set(existing.dropFirst(index + 1))
            let slot = result.firstIndex(where: { following.contains($0) }) ?? result.endIndex
            result.insert(id, at: slot)
            present.insert(id)
        }
        return result
    }

    private mutating func trim() {
        let pendingTurns = Set(submissions.values.map(\.turnID))
        var retained = Set(order.suffix(32))
        if let window, window.isLoaded {
            let windowTurns = window.turns.map { resolvedTurnID($0.id) }
            retained.formUnion(windowTurns)
            if let first = windowTurns.first, let start = order.firstIndex(of: first) { retained.subtract(order[..<start]) }
        }
        for id in order where !retained.contains(id) && !pendingTurns.contains(id) && turns[id]?.isActive != true {
            guard turns[id]?.items.values.contains(where: { $0.isLocal }) != true else { continue }
            turns.removeValue(forKey: id)
        }
        order.removeAll { turns[$0] == nil }
        guard let window else { return }
        let historyTurns = Dictionary(window.turns.map { (resolvedTurnID($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        for id in order { trimLiveItems(turnID: id, historyTurn: historyTurns[id]) }
    }

    private mutating func trimLiveItems(turnID: String) {
        guard let window else { return }
        trimLiveItems(turnID: turnID, historyTurn: historyTurn(turnID, in: window))
    }

    private mutating func trimLiveItems(turnID id: String, historyTurn: HistoryWindow.Turn?) {
        guard var turn = turns[id] else { return }
        var changed = false
        let retainedItems = Set(historyTurn?.entries.map(\.item.id) ?? [])
        // Only a retained detailed completion at least as new can own a live record.
        for entry in historyTurn?.entries ?? [] {
            guard let item = turn.items[entry.item.id], item.observedLive, item.completed,
                  let completedAt = item.completedAtMs, entry.isComplete == true,
                  let storedCompletion = entry.completedAtMs, storedCompletion >= completedAt else { continue }
            turn.items[entry.item.id]?.observedLive = false
            changed = true
        }
        let pendingItems = Set(submissions.values.filter { $0.turnID == id }.map { $0.message.id.uuidString })
        let localItems = Set(turn.items.compactMap { $0.value.isLocal ? $0.key : nil })
        let protected = retainedItems.union(pendingItems).union(localItems)
        var extra = turn.order.filter { !protected.contains($0) && turn.items[$0]?.observedLive == true }
        var bytes = extra.reduce(0) { $0 + (turn.items[$1]?.encodedBytes ?? 0) }
        while extra.count > 200 || (bytes > 4 * 1_024 * 1_024 && extra.count > 1) {
            let removed = extra.removeFirst()
            bytes -= turn.items[removed]?.encodedBytes ?? 0
            turn.hasDiscardedLiveItems = true
        }
        let keep = protected.union(extra)
        if turn.order.contains(where: { !keep.contains($0) }) || turn.items.keys.contains(where: { !keep.contains($0) }) {
            turn.order.removeAll { !keep.contains($0) }
            turn.items = turn.items.filter { keep.contains($0.key) }
            changed = true
        }
        if changed { turns[id] = turn }
    }

    mutating func toggleTimeline(_ id: String) {
        guard let timeline = ConversationProjection.project(self).timelines.first(where: { $0.id == id }) else { return }
        let anchors = Set(timeline.events.map(\.id)).union([timeline.id])
        if timeline.isExpanded { expandedTimelineAnchors.subtract(anchors) }
        else { expandedTimelineAnchors.formUnion(timeline.events.isEmpty ? [timeline.id] : timeline.events.map(\.id)) }
        revision += 1
    }

    private mutating func rememberExpandedActivity() {
        guard !expandedTimelineAnchors.isEmpty else { return }
        let expanded = ConversationProjection.project(self).timelines.filter(\.isExpanded)
        expandedTimelineAnchors = Set(expanded.flatMap { timeline in
            timeline.events.isEmpty ? [timeline.id] : timeline.events.map(\.id)
        })
    }

    func visibleItems(in turn: Turn) -> [String] {
        guard let window, window.isLoaded else { return turn.order }
        guard let observed = historyTurn(turn.id, in: window) else { return window.newer == nil ? turn.order : [] }
        let covered = Set(observed.entries.map(\.item.id))
        let latest = observed.entries.compactMap(\.startedAtOrdinal).max()
        let atTail = window.newer == nil && window.turns.last?.id == observed.id
        return turn.order.filter { id in
            guard let item = turn.items[id] else { return false }
            if covered.contains(id) || item.isLocal { return true }
            guard atTail, item.observedLive else { return false }
            return latest.map { boundary in item.position.map { $0 > boundary } ?? true } ?? true
        }
    }

    func showsOutcome(of turn: Turn) -> Bool {
        guard let window, window.isLoaded, window.newer != nil else { return true }
        return historyTurn(turn.id, in: window) != nil
    }

    private func historyTurn(_ id: String, in window: HistoryWindow) -> HistoryWindow.Turn? {
        window.turn(id) ?? window.turns.first { resolvedTurnID($0.id) == id }
    }

    mutating func recordTokenUsage(turnID: String, usage: CodexAppServerV2.ThreadTokenUsage) {
        tokenUsage = TokenUsageRecord(turnID: turnID, usage: usage)
        persistenceRevision += 1
    }

    var validTokenUsage: CodexAppServerV2.ThreadTokenUsage? {
        guard let tokenUsage, hasVerifiedTail, let window, window.isLoaded, window.newer == nil,
              let newest = window.turns.last, let metadata = newest.metadata, metadata.status != .inProgress,
              GatewayNotificationRouting.normalizeTurnID(newest.id) == GatewayNotificationRouting.normalizeTurnID(tokenUsage.turnID),
              order.last == resolvedTurnID(newest.id) else { return nil }
        return tokenUsage.usage
    }
}
