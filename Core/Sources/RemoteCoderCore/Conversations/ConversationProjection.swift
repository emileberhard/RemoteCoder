import Foundation
import OSLog

struct ConversationSnapshot: Sendable {
    let conversationID: UUID
    let ownerID: UUID
    let threadID: String?
    let revision: UInt64
    let messages: [ChatMessage]
    let timelines: [JobTimeline]
    let items: [ChatStreamItem]
    let lastTurnCompletedAt: Int64?
    var forkableMessageIDs: Set<UUID> = []
    var questionPrompts: [String: QuestionPrompt] = [:]
    var questionCoverage: QuestionHostSnapshot.Coverage = .unavailable
    /// Derived from the host replica and local delivery receipts, never a viewport.
    var pendingQuestion: QuestionPrompt? = nil
    var compaction: ConversationCompaction? = nil
    var canPrefetchOlder = false
    var presentationRows = TranscriptPresentationRows(rowIDs: [])
}

enum ConversationProjection {
    struct Memo: Sendable {
        fileprivate struct Inputs: Equatable, Sendable {
            let conversationID: UUID
            let threadID: String?
            let expandedTimelineAnchors: Set<String>
            let windowStamp: UInt64
            let order: [String]
            let membershipStamp: UInt64
            let deliveries: [UUID: DeliveryInput]
        }

        fileprivate struct DeliveryInput: Equatable, Sendable {
            let status: ConversationState.Submission.Status
            let isQueued: Bool
        }

        fileprivate struct Entry: Sendable {
            let stamp: UInt64
            let rows: [ChatStreamItem]
            let messages: [ChatMessage]
            let timelines: [JobTimeline]
            let forkableMessageID: UUID?
            let hasQuestions: Bool
            let userContentIDs: Set<String>
            let presentationRowIDs: Set<String>
            let visualPlacements: [String: VisualPlacement]
        }

        fileprivate struct VisualPlacement: Sendable {
            let text: String
            let references: [HTMLVisualReference]
        }

        fileprivate struct UserContent: Sendable {
            let source: [CodexAppServerV2.UserInput]
            let parsesVoice: Bool
            let text: String
            let attachments: [MessageAttachment]
            let inline: InlineMessageContent?
            let replies: [QuestionReply]?
        }

        fileprivate var revision: UInt64?
        fileprivate var userContents: [String: UserContent] = [:]
        fileprivate var inputs: Inputs?
        fileprivate var entries: [String: Entry] = [:]
        fileprivate(set) var projectedTurnCount = 0
        fileprivate var presentationRows = TranscriptPresentationRows(rowIDs: [])

        mutating func replace(with prepared: Memo, currentRevision: UInt64) {
            guard prepared.revision == currentRevision else { return }
            self = prepared
        }
    }

    struct Publication: Sendable {
        private var memo = Memo()
        private var publishedRows = TranscriptPresentationRows(rowIDs: [])
        private var publishedRevision: UInt64?

        var preparationMemo: Memo {
            var prepared = memo
            prepared.presentationRows = publishedRows
            return prepared
        }

        mutating func apply(_ prepared: (snapshot: ConversationSnapshot, memo: Memo), currentRevision: UInt64) -> ConversationSnapshot? {
            memo.replace(with: prepared.memo, currentRevision: currentRevision)
            guard publishedRevision.map({ prepared.snapshot.revision > $0 }) ?? true else { return nil }
            var snapshot = prepared.snapshot
            if snapshot.presentationRows.identity != publishedRows.identity,
               snapshot.presentationRows.rowIDs != publishedRows.rowIDs {
                publishedRows = snapshot.presentationRows
            }
            snapshot.presentationRows = publishedRows
            publishedRevision = snapshot.revision
            return snapshot
        }
    }

    nonisolated static let signposter = OSSignposter(subsystem: "RemoteCoder", category: "History")

    @concurrent
    static func render(_ state: ConversationState, memo: Memo, signposter: OSSignposter) async -> (snapshot: ConversationSnapshot, memo: Memo) {
        let interval = signposter.beginInterval("ConversationProjection", id: signposter.makeSignpostID(),
            "revision=\(state.revision) turns=\(state.order.count)")
        var memo = memo
        let snapshot = project(state, memo: &memo)
        signposter.endInterval("ConversationProjection", interval, "projected=\(memo.projectedTurnCount)")
        return (snapshot, memo)
    }

    static func project(_ state: ConversationState) -> ConversationSnapshot {
        var memo = Memo()
        return project(state, memo: &memo)
    }

    static func project(_ state: ConversationState, memo: inout Memo) -> ConversationSnapshot {
        let deliveries = state.submissions.compactMapValues { submission in
            submission.message.wasSteered || submission.queue != nil || sendDelivery(submission.status) != nil
                ? Memo.DeliveryInput(status: submission.status, isQueued: submission.queue != nil) : nil
        }
        let inputs = Memo.Inputs(conversationID: state.conversationID, threadID: state.threadID,
            expandedTimelineAnchors: state.expandedTimelineAnchors,
            windowStamp: state.windowStamp, order: state.order, membershipStamp: state.turns.membershipStamp,
            deliveries: deliveries)
        let reusable = memo.inputs == inputs ? memo.entries : [:]
        var userContents = memo.inputs?.conversationID == inputs.conversationID && memo.inputs?.threadID == inputs.threadID
            ? memo.userContents : [:]
        var retainedUserIDs = Set<String>()
        var entries: [String: Memo.Entry] = [:]
        var projectedTurnCount = 0
        var rows: [ChatStreamItem] = []
        var messages: [ChatMessage] = []
        var timelines: [JobTimeline] = []
        var forkableMessageIDs = Set<UUID>()
        var presentationRowIDs = Set<String>()
        var prompts = state.questionPrompts
        let pendingQuestion = prompts.values.filter(\.isPending).min { ($0.record?.ordinal ?? 0) < ($1.record?.ordinal ?? 0) }
        let threadID = state.threadID ?? state.conversationID.uuidString
        if let edge = state.window?.olderEdge { rows.append(.historyEdge(edge)) }
        for turnID in state.order {
            guard let turn = state.turns[turnID], let stamp = state.turns.stamp(of: turnID) else { continue }
            let entry: Memo.Entry
            if let reused = reusable[turnID], reused.stamp == stamp {
                entry = reused
            } else {
                entry = projectTurn(turn, stamp: stamp, previous: reusable[turnID], state: state, threadID: threadID, deliveries: deliveries, userContents: &userContents)
                projectedTurnCount += 1
            }
            entries[turnID] = entry
            retainedUserIDs.formUnion(entry.userContentIDs)
            presentationRowIDs.formUnion(entry.presentationRowIDs)
            if entry.hasQuestions || state.compaction?.turnID == turnID {
                for row in entry.rows {
                    switch row {
                    case .question(let local):
                        let prompt = prompts[local.itemID] ?? local
                        prompts[prompt.itemID] = prompt
                        rows.append(.question(prompt))
                    case .compaction(var marker):
                        if let current = state.compaction, current.turnID == turnID,
                           current.itemID == marker.compaction.itemID {
                            let canonical = marker.compaction
                            marker.compaction = current
                            // Runtime activity owns liveness; a retained transient
                            // running phase cannot animate an inactive history item.
                            if current.phase == .running || canonical.phase == .completed {
                                marker.compaction.phase = canonical.phase
                            }
                            marker.compaction.turnFinished = current.turnFinished || canonical.turnFinished
                        }
                        rows.append(.compaction(marker))
                    default: rows.append(row)
                    }
                }
            } else {
                rows.append(contentsOf: entry.rows)
            }
            messages.append(contentsOf: entry.messages)
            timelines.append(contentsOf: entry.timelines)
            if let id = entry.forkableMessageID { forkableMessageIDs.insert(id) }
        }
        let presentationRows = memo.presentationRows.rowIDs == presentationRowIDs
            ? memo.presentationRows : TranscriptPresentationRows(rowIDs: presentationRowIDs)
        memo = Memo(revision: state.revision, userContents: userContents.filter { retainedUserIDs.contains($0.key) }, inputs: inputs, entries: entries, projectedTurnCount: projectedTurnCount, presentationRows: presentationRows)
        // Admission can precede the first canonical item. Replace this provisional
        // row when that exact item arrives; never pin an off-page item to the tail.
        if let current = state.compaction, current.itemID == nil, let requestID = current.requestID,
           state.window?.newer == nil {
            rows.append(.compaction(CompactionMarker(id: "compaction-request-\(requestID)", compaction: current)))
        }
        if let edge = state.window?.newerEdge { rows.append(.historyEdge(edge)) }
        return ConversationSnapshot(conversationID: state.conversationID, ownerID: state.ownerID, threadID: state.threadID,
                                    revision: state.revision, messages: messages, timelines: timelines, items: rows,
                                    lastTurnCompletedAt: state.lastTurnCompletedAt,
                                    forkableMessageIDs: forkableMessageIDs, questionPrompts: prompts, questionCoverage: state.questions?.coverage ?? .unavailable, pendingQuestion: pendingQuestion, compaction: state.compaction,
                                    canPrefetchOlder: state.window.map { $0.olderEdge != nil && $0.hasRoomToPrefetch } ?? false,
                                    presentationRows: presentationRows)
    }

    private static func projectTurn(_ turn: ConversationState.Turn, stamp: UInt64, previous: Memo.Entry?, state: ConversationState, threadID: String,
                                    deliveries: [UUID: Memo.DeliveryInput], userContents: inout [String: Memo.UserContent]) -> Memo.Entry {
        var rows: [ChatStreamItem] = []
        var messages: [ChatMessage] = []
        var timelines: [JobTimeline] = []
        var forkableMessageID: UUID?
        var hasQuestions = false
        let ids = orderedVisibleIDs(in: turn, state: state)
        var latestPublication: [String: String] = [:]
        for id in ids {
            if let visual = turn.items[id]?.value.publishedVisual { latestPublication[visual.title] = id }
        }
        var visualPlacements: [String: Memo.VisualPlacement] = [:]
        if !latestPublication.isEmpty {
            for id in ids {
                guard let record = turn.items[id], record.completed,
                      case .agentMessage(_, let text, _, _, _) = record.value else { continue }
                if let cached = previous?.visualPlacements[id], cached.text == text {
                    visualPlacements[id] = cached
                } else {
                    visualPlacements[id] = Memo.VisualPlacement(text: text,
                        references: HTMLVisualReference.standaloneReferences(inMarkdown: text))
                }
            }
        }
        let placedVisuals = Set(visualPlacements.values.flatMap(\.references))
        let turnID = turn.id
        let jobID = GatewayNotificationRouting.jobID(threadID: threadID, turnID: turnID)
        if turn.hasDiscardedLiveItems { rows.append(.historyEdge(HistoryEdge(kind: .reload(turnID: turnID), cursor: nil))) }
        var events: [JobTimelineEvent] = []
        var queuedSteers: [ChatMessage] = []
        var precedingBoundary: (id: String, date: Date)?
        var userCount = 0
        var hasReply = false
        var hasCompaction = false
        var endsWithRunningCompaction = false

        func flush(before next: Date?, terminal: Bool) {
            guard !events.isEmpty || (terminal && turn.isActive && !endsWithRunningCompaction) else { return }
            let boundary = precedingBoundary?.id ?? "start"
            let id = "\(jobID)-seg-\(boundary)"
            let precedingDate = precedingBoundary?.date == .distantPast ? nil : precedingBoundary?.date
            let followingDate = next == .distantPast ? nil : next
            let started = JobTimelineSpan.startedAt(precedingMessageDate: precedingDate, events: events)
            let end = JobTimelineSpan.completedAt(followingMessageDate: terminal ? turn.completedAt : followingDate,
                                                  events: events, isRunning: terminal && turn.isActive)
            let active = terminal && turn.isActive
            let timeline = JobTimeline(id: id, startedAt: started,
                anchorDate: precedingDate ?? started ?? .distantPast, completedAt: active ? nil : end,
                isLive: active, isExpanded: state.expandedTimelineAnchors.contains(id)
                    || events.contains { state.expandedTimelineAnchors.contains($0.id) }, events: events)
            timelines.append(timeline)
            rows.append(.timeline(timeline))
            events.removeAll(keepingCapacity: true)
        }

        for (index, id) in ids.enumerated() {
            guard let record = turn.items[id] else { continue }
            if var message = message(record, threadID: threadID, turnID: turnID, wasSteered: userCount > 0, userContents: &userContents) {
                if message.wasSteered, record.isLocal {
                    message.delivery = steerDelivery(deliveries[message.id]?.status, turnIsActive: turn.isActive)
                    queuedSteers.append(message)
                    continue
                }
                var boundaryDate = message.date
                if message.role == .user {
                    userCount += 1
                    if message.wasSteered { message.delivery = .steered }
                    else if record.isLocal, let input = deliveries[message.id], input.isQueued {
                        message.delivery = queueDelivery(input.status)
                    } else if record.isLocal, let input = deliveries[message.id] {
                        message.delivery = sendDelivery(input.status)
                    }
                    if let receivedAtMs = record.completedAtMs {
                        boundaryDate = Date(timeIntervalSince1970: TimeInterval(receivedAtMs) / 1000)
                    }
                }
                flush(before: boundaryDate, terminal: false)
                endsWithRunningCompaction = false
                messages.append(message)
                if let questions = record.value.asyncQuestions {
                    // A question is content the user acts on, not a reply bubble.
                    let prompt = QuestionPrompt(itemID: record.value.id, turnID: turnID, date: record.date,
                        questions: questions.map(QuestionPrompt.Question.init))
                    rows.append(.question(prompt))
                    hasQuestions = true
                    precedingBoundary = (ChatStreamItem.questionRowID(itemID: prompt.itemID), message.date)
                    continue
                }
                rows.append(.message(message))
                if message.role == .codex { hasReply = true }
                precedingBoundary = (message.id.uuidString, boundaryDate)
                // The server forks through whole turns, never individual items.
                if index == ids.count - 1, message.role == .codex,
                   message.canonicalTurnID != nil, record.completed, record.detailed, !record.isLocal,
                   turn.terminalStatus == .completed, !turn.isActive,
                   state.window.map({ $0.newer == nil || $0.turns.last?.id != turnID }) ?? true {
                    forkableMessageID = message.id
                }
            } else if case .imageView(let itemID, let path) = record.value {
                let image = ViewedMedia(itemID: itemID, index: 0, path: path,
                                        caption: URL(fileURLWithPath: path).lastPathComponent)
                flush(before: record.date, terminal: false)
                rows.append(.viewedMedia(image))
                precedingBoundary = (image.rowID, record.date ?? .distantPast)
                endsWithRunningCompaction = false
            } else if case .contextCompaction(let itemID) = record.value {
                flush(before: record.date, terminal: false)
                let phase: ConversationCompaction.Phase
                if record.completed { phase = .completed }
                else if turn.terminalStatus == .failed { phase = .failed(turn.terminalError ?? "Compaction failed. Try again.") }
                else if turn.terminalStatus == .interrupted { phase = .interrupted }
                else { phase = turn.isActive ? .running : .unconfirmed }
                let marker = CompactionMarker(id: "compaction-\(jobID)-\(itemID)",
                    compaction: ConversationCompaction(turnID: turnID, itemID: itemID, phase: phase, turnFinished: turn.terminal))
                rows.append(.compaction(marker))
                precedingBoundary = (marker.id, record.date ?? .distantPast)
                hasCompaction = true
                endsWithRunningCompaction = !record.completed
            } else if let event = record.activity ?? ConversationItemPresentation.event(
                jobID: jobID, sequence: index, timestamp: record.date, item: record.value, completed: record.completed) {
                events.append(event)
                endsWithRunningCompaction = false
                if let publication = record.value.publishedVisual {
                    hasReply = true
                    if latestPublication[publication.title] == id, !placedVisuals.contains(publication.reference) {
                        flush(before: record.date, terminal: false)
                        let visual = PublishedVisual(itemID: record.value.id, publication: publication)
                        rows.append(.publishedVisual(visual))
                        precedingBoundary = (visual.rowID, record.date ?? .distantPast)
                    }
                }
                if let (tool, media) = record.value.toolMedia {
                    flush(before: record.date, terminal: false)
                    for (index, entry) in media.enumerated() {
                        let viewed = ViewedMedia(itemID: record.value.id, index: index, path: entry.path,
                                                 caption: entry.name ?? tool)
                        rows.append(.viewedMedia(viewed))
                        precedingBoundary = (viewed.rowID, record.date ?? .distantPast)
                    }
                }
            }
        }
        flush(before: nil, terminal: true)
        if state.showsOutcome(of: turn),
           let outcome = outcome(of: turn, hasReply: hasReply || (hasCompaction && timelines.isEmpty)) {
            rows.append(.turnOutcome(outcome))
        }
        for message in queuedSteers {
            messages.append(message)
            rows.append(.message(message))
        }
        let presentationRowIDs = Set(rows.map(\.id)).union(timelines.flatMap {
            $0.events.map { ChatStreamItem.activityRowID(eventID: $0.id) }
        })
        return Memo.Entry(stamp: stamp, rows: rows, messages: messages, timelines: timelines,
                          forkableMessageID: forkableMessageID, hasQuestions: hasQuestions,
                          userContentIDs: Set(ids.filter { id in
                              if case .userMessage = turn.items[id]?.value { true } else { false }
                          }), presentationRowIDs: presentationRowIDs, visualPlacements: visualPlacements)
    }

    private static func outcome(of turn: ConversationState.Turn, hasReply: Bool) -> TurnOutcome? {
        guard turn.reportsOutcome else { return nil }
        let date = turn.completedAt ?? .distantPast
        if turn.terminalStatus == .failed { return TurnOutcome(turnID: turn.id, kind: .failed(message: turn.terminalError), date: date) }
        return hasReply ? nil : TurnOutcome(turnID: turn.id, kind: .noReply, date: date)
    }

    private static func steerDelivery(_ status: ConversationState.Submission.Status?,
                                      turnIsActive: Bool) -> ChatMessage.Delivery {
        switch status {
        case .failed: .notSent
        case .submitting, .accepted: turnIsActive ? .pendingSteer : .unconfirmed
        case .queued, .uncertain, .confirmed, nil: .unconfirmed
        }
    }

    private static func sendDelivery(_ status: ConversationState.Submission.Status) -> ChatMessage.Delivery? {
        switch status {
        case .submitting: .sending
        case .uncertain: .unconfirmed
        case .failed: .notSent
        case .accepted, .queued, .confirmed: nil
        }
    }

    private static func queueDelivery(_ status: ConversationState.Submission.Status) -> ChatMessage.Delivery? {
        switch status {
        case .submitting: .queueing
        case .queued: .queued
        case .uncertain: .unconfirmed
        case .failed: .notSent
        case .accepted, .confirmed: nil
        }
    }

    /// Visible ids in display order. Unknown local/legacy observations retain
    /// their slots; source positions order every known record, even while a
    /// submission is waiting for canonical acknowledgement.
    private static func orderedVisibleIDs(in turn: ConversationState.Turn, state: ConversationState) -> [String] {
        var ids = state.visibleItems(in: turn).filter { turn.items[$0] != nil }
        let positionedSlots = ids.indices.filter { turn.items[ids[$0]]?.position != nil }
        let positioned = positionedSlots.map { ids[$0] }.sorted {
            let left = turn.items[$0]?.position ?? 0, right = turn.items[$1]?.position ?? 0
            return left == right ? $0 < $1 : left < right
        }
        for (slot, id) in zip(positionedSlots, positioned) { ids[slot] = id }
        return ids
    }

    private static func userContent(_ content: [CodexAppServerV2.UserInput], id: String, parsesVoice: Bool,
                                    cache: inout [String: Memo.UserContent]) -> Memo.UserContent {
        if let cached = cache[id], cached.source == content, cached.parsesVoice == parsesVoice { return cached }
        var attachments: [MessageAttachment] = []
        let parts = content.enumerated().compactMap { index, input -> String? in
            switch input {
            case .text(let value, _):
                if parsesVoice {
                    switch RealtimeVoiceMessagePresentation.parse(value) {
                    case .request(let input): return input
                    case .transcriptTail: return nil
                    case nil: break
                    }
                }
                return value
            case .image(let reference):
                attachments.append(MessageAttachment(id: ChatMessage.deterministicID(for: "\(id)|image:\(index)"), content: .image(reference)))
                return nil
            case .localImage(let path):
                attachments.append(MessageAttachment(id: ChatMessage.deterministicID(for: "\(id)|image:\(index)"), content: .localImage(path: path)))
                return nil
            case .skill(let name, let path), .mention(let name, let path): return "@\(name) (\(path))"
            }
        }
        let prepared = UserMessageText(parts.joined(separator: "\n\n"))
        var text = prepared.body
        attachments += prepared.filePaths.map {
            MessageAttachment(id: ChatMessage.deterministicID(for: "file:\($0)"), content: .fileReference(path: $0))
        }
        attachments.insert(contentsOf: prepared.pasted.map { MessageAttachment(id: $0.id, content: .text($0.text)) }, at: 0)
        var replies: [QuestionReply]?
        if let entries = QuestionReplyEnvelope.parse(text), !entries.isEmpty {
            replies = entries.map(\.reply)
            text = QuestionReply.displayText(entries.map(\.reply))
        }
        let result = Memo.UserContent(source: content, parsesVoice: parsesVoice, text: text, attachments: attachments, inline: prepared.inline.map(InlineMessageContent.init), replies: replies)
        cache[id] = result
        return result
    }

    private static func message(_ record: ConversationState.Item, threadID: String, turnID: String,
                                wasSteered: Bool, userContents: inout [String: Memo.UserContent]) -> ChatMessage? {
        let role: ChatMessage.Role
        let text: String
        let clientID: UUID?
        let attachments: [MessageAttachment]
        let questionReplies: [QuestionReply]?
        let inline: InlineMessageContent?
        switch record.value {
        case .userMessage(_, let content, let clientId):
            role = .user
            clientID = clientId.flatMap(UUID.init(uuidString:))
            if let local = record.localMessage, !local.text.isEmpty || !local.attachments.isEmpty {
                text = local.text
                let needsCanonicalImages = local.attachments.contains { if case .canonicalImage = $0.content { true } else { false } }
                let canonical = needsCanonicalImages ? userContent(content, id: record.value.id, parsesVoice: false, cache: &userContents).attachments.filter {
                    switch $0.content { case .image, .localImage: true; default: false }
                } : []
                attachments = local.attachments.map { attachment in
                    guard case .canonicalImage(let index) = attachment.content else { return attachment }
                    return MessageAttachment(id: attachment.id, content: canonical.indices.contains(index)
                        ? canonical[index].content : .unavailableImage)
                }
                inline = local.inlineContent
                questionReplies = local.questionReplies
            } else {
                let prepared = userContent(content, id: record.value.id, parsesVoice: record.localMessage == nil && clientId == nil,
                                           cache: &userContents)
                text = prepared.text
                attachments = prepared.attachments
                inline = prepared.inline
                questionReplies = prepared.replies
            }
        case .agentMessage(_, let value, _, _, _):
            role = .codex
            text = value
            clientID = nil
            attachments = []
            inline = nil
            questionReplies = nil
        default: return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return nil }
        let roleKey = role == .user ? "user" : "assistant"
        let id = record.localMessage?.id ?? clientID ?? ChatMessage.deterministicID(
            for: "thread:\(threadID)|turn:\(GatewayNotificationRouting.normalizeTurnID(turnID))|item:\(record.value.id)|role:\(roleKey)")
        return ChatMessage(id: id, role: role, text: text, attachments: attachments, inlineContent: inline,
                           date: record.localMessage?.date ?? record.date ?? .distantPast,
                           wasSteered: role == .user && (record.localMessage?.wasSteered ?? wasSteered),
                           canonicalTurnID: ConversationState.isLocalTurnID(turnID) ? nil : turnID,
                           canonicalItemID: record.completed ? record.value.id : nil,
                           questionReplies: questionReplies,
                           isStreaming: role == .codex && !record.completed)
    }
}
