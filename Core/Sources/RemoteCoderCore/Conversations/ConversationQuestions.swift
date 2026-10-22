import Foundation

extension ConversationState {
    var questionPrompts: [String: QuestionPrompt] {
        guard let inventory = questions, let epoch = inventory.epoch else { return [:] }
        var deliveries: [String: [QuestionPrompt.Delivery]] = [:]
        for (id, submission) in submissions.sorted(by: { $0.value.message.date < $1.value.message.date }) where submission.questionEpoch == epoch {
            for (itemID, entries) in Dictionary(grouping: submission.questionEntries ?? [], by: \.itemID) {
                deliveries[itemID, default: []].append(.init(id: id, status: submission.status, indices: Set(entries.map(\.index)), error: submission.deliveryError))
            }
        }
        return inventory.records.mapValues { record in
            QuestionPrompt(record: record, epoch: epoch, isCurrent: inventory.coverage == .ready &&
                (!record.isPending || inventory.isActionable(record)), deliveries: (deliveries[record.itemId] ?? []).filter { receipt in
                    receipt.indices.contains { index in record.questions.indices.contains(index) && record.questions[index].resolution != .answered }
                }, statusReason: inventory.reason)
        }
    }

    func validateQuestionSubmission(_ message: ChatMessage, input: String?, expectedVersion: QuestionVersion?) throws {
        guard message.questionReplies != nil else { return }
        guard let entries = QuestionReplyEnvelope.parse(input ?? message.text), !entries.isEmpty else {
            throw QuestionSubmissionError.invalid
        }
        guard Set(entries.map { "\($0.itemID)|\($0.index)" }).count == entries.count else {
            throw QuestionSubmissionError.invalid
        }
        for entry in entries {
            guard let record = questions?.records[entry.itemID], questions?.coverage == .ready,
                  questions?.epoch == expectedVersion?.epoch, record.revision == expectedVersion?.revision, record.questions.indices.contains(entry.index),
                  !entry.reply.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw QuestionSubmissionError.stale }
            let duplicate = submissions.values.contains { submission in
                submission.status != .failed && submission.questionEntries?.contains {
                    $0.itemID == entry.itemID && $0.index == entry.index
                } == true
            }
            guard !duplicate else { throw QuestionSubmissionError.inFlight }
        }
    }

    @discardableResult
    mutating func confirmQuestionReceipts() -> Bool {
        guard let questions, questions.coverage == .ready else { return false }
        var changed = false
        for (id, submission) in submissions where submission.questionIsConfirmed(by: questions) {
            if contains(clientID: id) { submissions.removeValue(forKey: id); changed = true }
            else if submission.status != .confirmed { submissions[id]?.status = .confirmed; changed = true }
        }
        return changed
    }

    enum QuestionSubmissionError: LocalizedError {
        case invalid, stale, inFlight, notReady
        var errorDescription: String? {
            switch self {
            case .notReady: "The conversation is not ready to send yet."
            case .invalid: "Every submitted question needs a valid answer."
            case .stale: "The question changed. Refresh its status before answering."
            case .inFlight: "This question already has an answer in delivery. Check its status before sending again."
            }
        }
    }
}

extension ConversationState.Submission {
    func questionIsConfirmed(by inventory: QuestionInventory?) -> Bool {
        guard let inventory, inventory.coverage == .ready, questionEpoch == inventory.epoch, let entries = questionEntries, !entries.isEmpty else { return false }
        return entries.allSatisfy { entry in
            guard let answer = inventory.records[entry.itemID]?.questions.first(where: { $0.index == entry.index })?.answer else { return false }
            if answer.clientId.flatMap(UUID.init(uuidString:)) == message.id { return true }
            return status == .confirmed && canonicalQuestionOrdinal.map { answer.ordinal >= $0 } == true
        }
    }
}
