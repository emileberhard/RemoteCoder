import Foundation
import Testing
@testable import RemoteCoderCore

struct TranscriptSearchTests {
    @Test func matchesMessageRowsInTranscriptOrderIgnoringCaseAndDiacritics() {
        let question = message(.user, "Why does the Café build fail?")
        let answer = message(.codex, "The cafe target misses a flag.")
        let other = message(.codex, "Done.")
        let items: [ChatStreamItem] = [.message(question), .message(other), .message(answer)]

        #expect(TranscriptSearch.matchingRowIDs("CAFE", in: items) == [ChatStreamItem.message(question).id,
                                                                        ChatStreamItem.message(answer).id])
    }

    @Test func blankQueriesAndNonMessageRowsNeverMatch() {
        let outcome = TurnOutcome(turnID: "turn", kind: .failed(message: "cafe crashed"), date: .distantPast)
        let items: [ChatStreamItem] = [.turnOutcome(outcome), .message(message(.codex, "cafe"))]

        #expect(TranscriptSearch.matchingRowIDs("   ", in: items).isEmpty)
        #expect(TranscriptSearch.matchingRowIDs("crashed", in: items).isEmpty)
    }

    @Test func answeredQuestionsAreSearchedAsTheyAreShown() {
        var reply = message(.user, "<envelope>raw reply payload</envelope>")
        reply.questionReplies = [QuestionReply(question: "Which branch?", answer: "Use main")]
        let items: [ChatStreamItem] = [.message(reply)]

        #expect(TranscriptSearch.matchingRowIDs("branch", in: items) == [ChatStreamItem.message(reply).id])
        #expect(TranscriptSearch.matchingRowIDs("use main", in: items) == [ChatStreamItem.message(reply).id])
        #expect(TranscriptSearch.matchingRowIDs("payload", in: items).isEmpty)
    }

    private func message(_ role: ChatMessage.Role, _ text: String) -> ChatMessage {
        ChatMessage(role: role, text: text)
    }
}
