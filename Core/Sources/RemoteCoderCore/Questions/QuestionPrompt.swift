import Foundation

/// Historical metadata, host facts and a local delivery receipt for one card.
/// Missing host facts never make a question actionable.
struct QuestionPrompt: Identifiable, Hashable, Sendable {
    struct Question: Hashable, Sendable {
        let title: String
        /// Empty for a free-text-only question. The tool contract puts the
        /// recommended answer first.
        let options: [String]

        init(title: String, options: [String]) {
            self.title = title
            self.options = options
        }

        init(_ question: CodexAppServerV2.AsyncUserInputQuestion) {
            self.init(title: question.title, options: question.options ?? [])
        }
    }

    struct Delivery: Hashable, Sendable {
        let id: UUID
        let status: ConversationState.Submission.Status
        let indices: Set<Int>
        var error: String? = nil
        var preventsSend: Bool { status != .failed }
        var description: String {
            switch status {
            case .submitting: "Sending answer…"
            case .accepted: "Answer received; waiting for confirmation…"
            case .queued: "Answer queued until the running turn ends…"
            case .confirmed: "Answer confirmed; refreshing question…"
            case .uncertain: "Delivery is uncertain. \(error ?? "Check status before sending again.")"
            case .failed: "The answer was not accepted. \(error ?? "You can retry.")"
            }
        }
    }

    let itemID: String
    let turnID: String
    let date: Date?
    let questions: [Question]
    var record: QuestionRecord?
    var epoch: String?
    var statusReason: String?
    var isCurrent = false
    var deliveries: [Delivery] = []

    var id: String { itemID }
    var version: QuestionVersion? {
        guard let epoch, let record else { return nil }
        return .init(epoch: epoch, revision: record.revision)
    }
    var pendingIndices: [Int] {
        record?.questions.filter { slot in
            slot.resolution == .pending && !deliveries.contains { $0.preventsSend && $0.indices.contains(slot.index) }
        }.map(\.index) ?? []
    }
    var isPending: Bool { isCurrent && !pendingIndices.isEmpty }
    var isResolved: Bool { isCurrent && record?.isPending == false }

    init(itemID: String, turnID: String, date: Date?, questions: [Question]) {
        self.itemID = itemID
        self.turnID = turnID
        self.date = date
        self.questions = questions
    }

    init(record: QuestionRecord, epoch: String, isCurrent: Bool, deliveries: [Delivery], statusReason: String? = nil) {
        itemID = record.itemId
        turnID = record.turnId
        date = record.askedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        questions = record.questions.map { Question(title: $0.title, options: $0.options) }
        self.record = record
        self.epoch = epoch
        self.statusReason = statusReason
        self.isCurrent = isCurrent
        self.deliveries = deliveries
    }
}

struct QuestionAddress: Hashable, Identifiable, Sendable {
    let conversation: ConversationAddress
    let itemID: String
    var id: String { "\(conversation.id)|\(itemID)" }
}
