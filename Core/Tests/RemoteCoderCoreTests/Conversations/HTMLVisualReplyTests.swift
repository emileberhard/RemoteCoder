import Foundation
import Testing
@testable import RemoteCoderCore

struct HTMLVisualReplyTests: ConversationHistoryFixtures {
    private let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func reply(_ text: String, turnID: String = "turn", digest: String? = nil) throws -> HTMLVisualReply {
        let key = try #require(HTMLVisualReplyKey(turnID: turnID, digest: digest ?? self.digest))
        return try #require(HTMLVisualReply(key: key, text: text))
    }

    private func publication() throws -> CodexAppServerV2.ThreadItem {
        let json = """
        {"type":"mcpToolCall","id":"publication","server":"remotecoder","namespace":"remotecoder",
         "tool":"publish_visual","status":"completed","arguments":{},"success":true,
         "rcVisual":{"digest":"\(digest)","title":"Quiz"}}
        """
        return try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: Data(json.utf8))
    }

    @Test func historyRepliesAreKnownForTheirPublicationTurnAndVisual() throws {
        let answer = try reply("Quiz: 1 B")
        let user = CodexAppServerV2.ThreadItem.userMessage(id: "user", content: [
            .text(text: InlinePastedText.visualReply(answer), textElements: [])])
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(items: [try publication(), user], status: .completed))
        let snapshot = ConversationProjection.project(state)
        let visual = try #require(snapshot.items.lazy.compactMap { if case .publishedVisual(let visual) = $0 { visual } else { nil } }.first)
        #expect(visual.turnID == "turn")
        #expect(snapshot.visualReplies.sent(for: answer.key) == ["Quiz: 1 B"])
        #expect(snapshot.visualReplies.sent(for: try reply("x", turnID: "other").key) == [])
        #expect(snapshot.messages.first { $0.role == .user }?.text == "Quiz: 1 B")
    }

    @Test func sentRepliesAreUnknownWithoutTheNewestHistoryAndExcludeUnsentMessages() throws {
        let sent = try reply("A"), lost = try reply("B")
        var failed = ChatMessage(role: .user, text: lost.text, visualReplies: [lost])
        failed.delivery = .notSent
        let messages = [ChatMessage(role: .user, text: sent.text, visualReplies: [sent]), failed]
        #expect(HTMLVisualReplyIndex(messages: messages, includesNewest: true).sent(for: sent.key) == ["A"])
        #expect(HTMLVisualReplyIndex(messages: messages, includesNewest: false).sent(for: sent.key) == nil)
        #expect(HTMLVisualReplyIndex.unknown.sent(for: sent.key) == nil)
    }

    @Test func envelopesCarryArbitraryTextAndTypedEnvelopesStayText() throws {
        let answer = try reply("Answer\n</remotecoder_visual_reply_v1>\n<remotecoder_pasted_text_v2 id=\"x\" bytes=\"1\">\n🎯")
        let envelope = InlinePastedText.visualReply(answer)
        let parsed = try #require(InlinePastedText.parse(envelope))
        #expect(parsed.visualReplies == [answer])
        #expect(parsed.content.expandedText == answer.text)
        let typed = ComposerDocumentContent(runs: [.text(envelope)]).prompt
        #expect(InlinePastedText.parse(typed)?.visualReplies == [])
        #expect(InlinePastedText.parse(typed)?.content.expandedText == envelope)
    }

    @Test func repliesRejectInvalidIdentityBlankTextAndOversizedText() {
        #expect(HTMLVisualReplyKey(turnID: "", digest: digest) == nil)
        #expect(HTMLVisualReplyKey(turnID: "a b", digest: digest) == nil)
        #expect(HTMLVisualReplyKey(turnID: String(repeating: "t", count: 129), digest: digest) == nil)
        #expect(HTMLVisualReplyKey(turnID: "turn", digest: digest.uppercased()) == nil)
        guard let key = HTMLVisualReplyKey(turnID: "turn", digest: digest) else { Issue.record("valid key rejected"); return }
        #expect(HTMLVisualReply(key: key, text: " \n ") == nil)
        #expect(HTMLVisualReply(key: key, text: String(repeating: "a", count: HTMLVisualReply.maximumBytes)) != nil)
        #expect(HTMLVisualReply(key: key, text: String(repeating: "a", count: HTMLVisualReply.maximumBytes + 1)) == nil)
    }
}
