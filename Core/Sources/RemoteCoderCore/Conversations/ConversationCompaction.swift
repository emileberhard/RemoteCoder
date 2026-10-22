import Foundation

struct ConversationCompaction: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case requesting, running, completed, interrupted
        case failed(String)
        case unconfirmed
    }

    var requestID: UUID?
    var turnID: String?
    var itemID: String?
    var phase: Phase
    var turnFinished = false

    var isActive: Bool { phase == .requesting || phase == .running }
    var awaitsTurnOutcome: Bool { isActive || phase == .unconfirmed || phase == .completed && !turnFinished }
    var blocksSending: Bool { requestID != nil && awaitsTurnOutcome }
}

extension ConversationState {
    mutating func beginCompaction(_ requestID: UUID) -> Bool {
        guard compaction?.blocksSending != true else { return false }
        compaction = ConversationCompaction(requestID: requestID, phase: .requesting)
        compactionBaselineTurns = Set(turns.keys)
        compactionSequence = latestNotificationSequence
        revision += 1
        return true
    }

    mutating func compactionRequestFailed(_ requestID: UUID, message: String, deliveryUncertain: Bool) {
        guard compaction?.requestID == requestID, compaction?.blocksSending == true,
              compaction?.phase != .completed else { return }
        compaction?.phase = deliveryUncertain ? .unconfirmed : .failed(message)
        revision += 1
    }

    mutating func clearFinishedCompaction() {
        guard compaction != nil, compaction?.blocksSending != true else { return }
        compaction = nil
        compactionBaselineTurns = []
        compactionSequence = nil
        revision += 1
    }

    mutating func compactionIdleConfirmed(requestID: UUID?, turnID: String?) {
        guard compaction?.blocksSending == true, compaction?.requestID == requestID,
              requestID != nil || compaction?.turnID == turnID else { return }
        compaction?.turnFinished = true
        if compaction?.phase != .completed {
            compaction?.phase = .failed("Compaction result could not be confirmed. You can continue or try again.")
        }
        revision += 1
    }

    mutating func observeCompaction(_ event: TurnScopedGatewayEvent, replay: Bool, turnID: String) {
        if let fence = compactionSequence, let sequence = event.note.sequence, sequence <= fence { return }
        if compaction?.requestID != nil, compactionBaselineTurns.contains(turnID) { return }
        switch event.note.server {
        case .turnStarted:
            if compaction?.requestID != nil, compaction?.turnID == nil, compaction?.blocksSending == true,
               !replay || compactionSequence != nil && event.note.sequence != nil {
                compaction?.turnID = turnID
            }
        case .itemStarted(let item), .itemCompleted(let item):
            guard case .contextCompaction = item.item else { return }
            guard !replay || compaction?.turnID == turnID ||
                compaction?.blocksSending == true && compactionSequence != nil && event.note.sequence != nil else { return }
            let complete = event.method == "item/completed"
            if !complete, compaction?.turnID == turnID, compaction?.itemID == item.item.id,
               compaction?.phase == .completed { return }
            if let current = compaction, current.blocksSending, let currentTurn = current.turnID,
               currentTurn != turnID { return }
            let requestID = compaction?.blocksSending == true || compaction?.turnID == turnID ? compaction?.requestID : nil
            compaction = ConversationCompaction(requestID: requestID, turnID: turnID,
                                               itemID: item.item.id, phase: complete ? .completed : .running,
                                               turnFinished: turns[turnID]?.terminal == true)
        case .turnCompleted(let completion):
            guard compaction?.turnID == turnID, compaction?.awaitsTurnOutcome == true else { return }
            compaction?.turnFinished = true
            if compaction?.phase == .completed { return }
            switch completion.status {
            case .failed:
                compaction?.phase = .failed(completion.errorMessage ?? "Compaction failed. Try again.")
            case .interrupted:
                compaction?.phase = .interrupted
            case .completed, .inProgress, nil:
                // A finished turn alone does not prove that context was compacted.
                compaction?.phase = .unconfirmed
            }
        default: break
        }
    }

    mutating func reconcileCompactionFromHistory() {
        guard let current = compaction, current.blocksSending, let currentTurn = current.turnID else { return }
        for id in order.reversed() where !compactionBaselineTurns.contains(id) {
            guard currentTurn == id, let turn = turns[id] else { continue }
            for itemID in turn.order.reversed() {
                guard let item = turn.items[itemID], case .contextCompaction = item.value else { continue }
                if item.completed {
                    compaction = ConversationCompaction(requestID: current.requestID, turnID: id,
                                                       itemID: itemID, phase: .completed, turnFinished: turn.terminal)
                } else if turn.terminalStatus == .failed {
                    compaction?.phase = .failed(turn.terminalError ?? "Compaction failed. Try again.")
                } else if turn.terminalStatus == .interrupted {
                    compaction?.phase = .interrupted
                }
                return
            }
        }
    }
}
