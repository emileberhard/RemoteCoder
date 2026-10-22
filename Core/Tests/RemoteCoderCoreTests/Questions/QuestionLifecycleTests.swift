import Foundation
import Testing
@testable import RemoteCoderCore

struct QuestionLifecycleTests {
    private struct Incident: Decodable {
        let summary: CodexAppServerV2.Turn
        let canonicalItems: [CodexAppServerV2.ThreadItemsListResponse.Entry]
        let laterPage: LaterPage
    }
    private struct LaterPage: Decodable {
        let nextCursor: String?
    }
    private func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: ProtocolFixtures.data(named: name))
    }

    @Test(arguments: [false, true]) func answerOutsideViewportNeverReturnsToPending(warm: Bool) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let incident = try fixture("answered-outside-viewport", as: Incident.self)
        let host = try fixture("answered-snapshot", as: QuestionHostSnapshot.self)
        let laterItems = Array(incident.canonicalItems.suffix(50).reversed())
        #expect(laterItems.count == 50)
        #expect(laterItems.first?.startedAtOrdinal == 1034)
        #expect(laterItems.last?.startedAtOrdinal == 985)
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "thread",
            checkpoints: .init(hostID: UUID(), storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024))
        if warm {
            _ = await session.merge(.fixture(wire: incident.canonicalItems.reversed(), turns: [incident.summary]))
            _ = try await session.mergeQuestions(host)
        }
        let before = await session.merge(.fixture(wire: laterItems, turns: [incident.summary],
            older: incident.laterPage.nextCursor, placement: .reset))
        #expect(before.pendingQuestion == nil)
        let after = try await session.mergeQuestions(host)
        #expect(after.pendingQuestion == nil)
        #expect(after.questionPrompts["call_question"]?.record?.questions[0].answer?.text == "External")
        #expect(await session.beginHistoryRead().base?.turn("turn")?.entries.first?.startedAtOrdinal == 985)
        #expect(!after.items.contains { $0.id == ChatStreamItem.questionRowID(itemID: "call_question") })
    }

    @Test func staleSparseAndUnknownSnapshotsPreserveKnownAnswers() throws {
        var inventory = QuestionInventory()
        let answered = try fixture("answered-snapshot", as: QuestionHostSnapshot.self)
        try inventory.merge(answered)
        let record = answered.records[0]
        let pending = QuestionRecord(itemId: record.itemId, turnId: record.turnId, ordinal: record.ordinal, askedAtMs: nil,
            revision: 1, questions: [.init(index: 0, title: "Which deployment?", options: [], resolution: .pending, answer: nil)])
        try inventory.merge(snapshot(records: [pending], revision: 1))
        #expect(inventory.records[record.id]?.questions[0].resolution == .answered)
        inventory.invalidate("offline")
        #expect(inventory.records[record.id]?.questions[0].resolution == .answered)
        #expect(!inventory.isActionable(record))
        try inventory.merge(snapshot(records: [], revision: 4))
        #expect(inventory.records[record.id]?.questions[0].resolution == .answered)
        try inventory.merge(.init(threadId: "thread", epoch: "replacement", revision: 1, coverage: .ready,
            reason: nil, records: [pending], pendingItemIds: [pending.id], missingItemIds: []))
        #expect(inventory.isActionable(pending))
    }

    @Test func malformedInventoryCannotClaimKnownEmptyOrResolvedWithoutAnAnswer() {
        let invalid = QuestionHostSnapshot(threadId: "thread", epoch: "e", revision: 1, coverage: .ready,
            reason: nil, records: [], pendingItemIds: nil, missingItemIds: [])
        #expect(throws: (any Error).self) { try invalid.validate() }
        let record = QuestionRecord(itemId: "q", turnId: "turn", ordinal: 0, askedAtMs: nil, revision: 1,
            questions: [.init(index: 0, title: "Q", options: [], resolution: .answered, answer: nil)])
        #expect(throws: (any Error).self) { try snapshot(records: [record]).validate() }
    }

    @Test(arguments: [ConversationState.Submission.Status.submitting, .accepted, .uncertain, .confirmed, .failed])
    func deliveryOverlayIsPerSlotAndDoesNotInventResolution(status: ConversationState.Submission.Status) throws {
        var state = try pendingState()
        let message = answer(index: 0)
        state.submit(message, input: envelope(index: 0))
        state.submissions[message.id]?.status = status
        let projected = ConversationProjection.project(state)
        let prompt = try #require(projected.pendingQuestion)
        #expect(prompt.pendingIndices == (status == .failed ? [0, 1] : [1]))
        #expect(prompt.record?.questions.map(\.resolution) == [.pending, .pending])
    }

    @Test func acceptedReceiptSurvivesDisconnectAndCheckpointRestore() throws {
        var state = try pendingState()
        let message = answer(index: 0)
        state.submit(message, input: envelope(index: 0))
        state.accepted(message.id, turnID: "turn")
        state.submissionFailed(message.id, failure: .uncertain("test lost connection"))
        #expect(state.submissions[message.id]?.status == .accepted)
        var restored = ConversationState(conversationID: state.conversationID, threadID: "thread")
        restored.restore(try JSONDecoder().decode(ConversationState.Checkpoint.self, from: JSONEncoder().encode(state.checkpoint)))
        #expect(restored.submissions[message.id]?.status == .accepted)
        #expect(restored.questions?.coverage == .unavailable)
        #expect(ConversationProjection.project(restored).pendingQuestion == nil)
        restored.questions = state.questions
        #expect(ConversationProjection.project(restored).pendingQuestion?.pendingIndices == [1])
    }

    @Test func interruptedLocalSubmissionRestoresAsUncertainNeverAsAnAutomaticRetry() throws {
        var state = try pendingState()
        let message = answer(index: 0)
        state.submit(message, input: envelope(index: 0))
        var restored = ConversationState(conversationID: state.conversationID, threadID: "thread")
        restored.restore(state.checkpoint)
        #expect(restored.submissions[message.id]?.status == .uncertain)
        restored.questions = state.questions
        #expect(throws: ConversationState.QuestionSubmissionError.inFlight) { try restored.validateQuestionSubmission(answer(index: 0), input: envelope(index: 0), expectedVersion: .init(epoch: "fixture-epoch", revision: 1)) }
    }

    @Test func duplicateAndStaleSubmissionAreRejectedButOtherSlotsRemainAvailable() throws {
        var state = try pendingState()
        let first = answer(index: 0)
        try state.validateQuestionSubmission(first, input: envelope(index: 0), expectedVersion: .init(epoch: "fixture-epoch", revision: 1))
        state.submit(first, input: envelope(index: 0))
        #expect(throws: (any Error).self) { try state.validateQuestionSubmission(answer(index: 0), input: envelope(index: 0), expectedVersion: .init(epoch: "fixture-epoch", revision: 1)) }
        #expect(throws: ConversationState.QuestionSubmissionError.stale) { try state.validateQuestionSubmission(answer(index: 1), input: envelope(index: 1), expectedVersion: .init(epoch: "different-history", revision: 1)) }
        try state.validateQuestionSubmission(answer(index: 1), input: envelope(index: 1), expectedVersion: .init(epoch: "fixture-epoch", revision: 1))
        #expect(throws: (any Error).self) { try state.validateQuestionSubmission(answer(index: 1), input: envelope(index: 1), expectedVersion: .init(epoch: "fixture-epoch", revision: 0)) }
    }

    @Test func oldReceiptsDoNotSuppressQuestionsInAReplacementHistory() throws {
        var state = try pendingState()
        let message = answer(index: 0)
        state.submit(message, input: envelope(index: 0))
        state.accepted(message.id, turnID: "turn")
        try state.questions?.merge(.init(threadId: "thread", epoch: "replacement", revision: 1, coverage: .ready,
            reason: nil, records: [record()], pendingItemIds: ["q"], missingItemIds: []))
        let prompt = try #require(ConversationProjection.project(state).pendingQuestion)
        #expect(prompt.pendingIndices == [0, 1])
        #expect(prompt.deliveries.isEmpty)
        #expect(state.submissions[message.id]?.status == .accepted)
    }

    @Test func canonicalAnswerCanConfirmALostAcknowledgmentOutsideTheViewport() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "thread",
            checkpoints: .init(hostID: UUID(), storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024))
        let pending = try pendingState()
        _ = try await session.mergeQuestions(snapshot(records: Array(try #require(pending.questions).records.values)))
        let message = answer(index: 0)
        _ = try await session.submitDurably(message, input: envelope(index: 0), expectedQuestionVersion: .init(epoch: "fixture-epoch", revision: 1))
        await session.submissionFailed(message.id, failure: .uncertain("test lost connection"))
        let result = try await session.mergeQuestions(snapshot(records: [record(answeredBy: message.id)], revision: 2))
        let prompt = try #require(result.questionPrompts["q"])
        #expect(prompt.record?.questions[0].resolution == .answered)
        #expect(prompt.deliveries.isEmpty)
        #expect(prompt.pendingIndices == [1])
    }

    @Test func localSaveFailureCannotCreateAResolvedQuestionOrDispatchReceipt() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let session = await ConversationSession.make(conversationID: UUID(), threadID: "thread",
            checkpoints: .init(hostID: UUID(), directory: root, primaryBudgetBytes: 512 * 1_024 * 1_024))
        _ = try await session.mergeQuestions(snapshot(records: [record()]))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        await #expect(throws: (any Error).self) {
            try await session.submitDurably(answer(index: 0), input: envelope(index: 0), expectedQuestionVersion: .init(epoch: "fixture-epoch", revision: 1))
        }
        let result = await session.snapshot()
        #expect(result.questionPrompts["q"]?.pendingIndices == [0, 1])
        #expect(result.questionPrompts["q"]?.deliveries.isEmpty == true)
    }

    @Test func missingCheckpointQuestionFieldMeansUnavailable() throws {
        let old = #"{"revision":1,"threadID":"thread","order":[],"turns":{},"submissions":[]}"#
        let checkpoint = try JSONDecoder().decode(ConversationState.Checkpoint.self, from: Data(old.utf8))
        var restored = ConversationState(conversationID: UUID(), threadID: "thread")
        restored.restore(checkpoint)
        #expect(ConversationProjection.project(restored).questionCoverage == .unavailable)
    }

    private func pendingState() throws -> ConversationState {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        var inventory = QuestionInventory()
        try inventory.merge(snapshot(records: [record()]))
        state.questions = inventory
        return state
    }
    private func record(answeredBy id: UUID? = nil) -> QuestionRecord {
        .init(itemId: "q", turnId: "turn", ordinal: 956, askedAtMs: nil, revision: id == nil ? 1 : 2,
            questions: (0..<2).map { index in
                let answered = id != nil && index == 0
                return .init(index: index, title: "Q\(index)", options: ["A", "B"], resolution: answered ? .answered : .pending,
                    answer: answered ? .init(text: "B", itemId: "reply", clientId: id?.uuidString, ordinal: 976, atMs: nil) : nil)
            })
    }
    private func snapshot(records: [QuestionRecord], revision: UInt64 = 1) -> QuestionHostSnapshot {
        .init(threadId: "thread", epoch: "fixture-epoch", revision: revision, coverage: .ready, reason: nil,
            records: records, pendingItemIds: records.filter(\.isPending).map(\.id), missingItemIds: [])
    }
    private func answer(index: Int) -> ChatMessage {
        .init(role: .user, text: "B", questionReplies: [.init(question: "Q\(index)", answer: "B")])
    }
    private func envelope(index: Int) -> String {
        QuestionReplyEnvelope.text(entries: [.init(itemID: "q", index: index, reply: .init(question: "Q\(index)", answer: "B"))])
    }
}
