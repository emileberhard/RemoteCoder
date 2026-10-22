import Foundation
import Testing
@testable import RemoteCoderCore

struct QuestionReplyEnvelopeTests {
    @Test func envelopeRoundTripsInQuestionOrderWithDesktopIdentifiers() throws {
        let replies = [
            QuestionReply(question: "Which approach?", answer: "Patch"),
            QuestionReply(question: "Why?", answer: "It's smaller & safer / faster"),
        ]
        let text = QuestionReplyEnvelope.text(itemID: "call_abc", replies: replies)
        #expect(text.hasPrefix(QuestionReplyEnvelope.openTag + "\n"))
        #expect(text.hasSuffix("\n" + QuestionReplyEnvelope.closeTag))
        #expect(text.contains(#""questionItemId":"[\"request_user_input_async\",\"call_abc\",0]""#))
        #expect(!text.contains("\\/"))

        let entries = try #require(QuestionReplyEnvelope.parse(text))
        #expect(entries.map(\.itemID) == ["call_abc", "call_abc"])
        #expect(entries.map(\.index) == [0, 1])
        #expect(entries.map(\.reply) == replies)
        #expect(QuestionReply.displayText(replies) == "Patch\n\nIt's smaller & safer / faster")
    }

    @Test func parsesTheDesktopSampleAndASingleObjectBody() throws {
        let desktop = """
        <send_user_message_question_reply>
        [{"questionItemId":"[\\"request_user_input_async\\",\\"call_zqp\\",0]","question":"Which branch?","answer":"main"}]
        </send_user_message_question_reply>
        """
        let entries = try #require(QuestionReplyEnvelope.parse(desktop))
        #expect(entries == [.init(itemID: "call_zqp", index: 0, reply: .init(question: "Which branch?", answer: "main"))])

        let single = """
          <send_user_message_question_reply>{"questionItemId":"[\\"request_user_input_async\\",\\"call_1\\",2]","question":"Q","answer":"A"}</send_user_message_question_reply>
        """
        #expect(QuestionReplyEnvelope.parse(single)?.map(\.index) == [2])
    }

    @Test func nonEnvelopesAndMalformedBodiesAreNotReplies() {
        #expect(QuestionReplyEnvelope.parse("Just a message") == nil)
        #expect(QuestionReplyEnvelope.parse("Say <send_user_message_question_reply>[]</send_user_message_question_reply> back") == nil)
        #expect(QuestionReplyEnvelope.parse("<send_user_message_question_reply>not json</send_user_message_question_reply>") == nil)
        #expect(QuestionReplyEnvelope.parse("<send_user_message_question_reply>\"string\"</send_user_message_question_reply>") == nil)
        // An envelope whose entries name another tool or lack fields carries no replies.
        let foreign = """
        <send_user_message_question_reply>[{"questionItemId":"[\\"other_tool\\",\\"call_1\\",0]","question":"Q","answer":"A"},{"questionItemId":"[\\"request_user_input_async\\",\\"call_1\\",-1]","question":"Q","answer":"A"},{"question":"Q"}]</send_user_message_question_reply>
        """
        #expect(QuestionReplyEnvelope.parse(foreign) == [])
    }

    @Test func questionItemIDsPreserveCallIDsWithSpecialCharacters() {
        let raw = QuestionReplyEnvelope.questionItemID(itemID: "call/with \"quotes\"", index: 3)
        let parsed = QuestionReplyEnvelope.parseQuestionItemID(raw)
        #expect(parsed?.itemID == "call/with \"quotes\"")
        #expect(parsed?.index == 3)
    }
}
