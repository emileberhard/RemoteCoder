import Foundation
import Testing
@testable import RemoteCoderCore

struct VisualPublicationTests: ConversationHistoryFixtures {
    private let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private var embed: String { "![Chart](rc-visual:\(digest))" }

    private func publication(_ type: String, id: String = "publication", title: String = "Chart", referenceDigest: String? = nil) throws -> CodexAppServerV2.ThreadItem {
        let json = """
        {"type":"\(type)","id":"\(id)","server":"remotecoder","namespace":"remotecoder",
         "tool":"publish_visual","status":"completed","arguments":{},"success":true,
         "rcVisual":{"digest":"\(referenceDigest ?? digest)","title":"\(title)"}}
        """
        return try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: Data(json.utf8))
    }

    @Test(arguments: ["mcpToolCall", "dynamicToolCall"])
    func successfulPublicationIsVisibleWithoutAnAuthoredReplyAndSurvivesHistoryAndCheckpoint(type: String) throws {
        let item = try publication(type)
        var live = ConversationState(conversationID: UUID(), threadID: "thread")
        live.apply(try event("item/completed", item: item, ordinal: 1))
        live.apply(try GatewayEventFixture.turn(.object(["threadId": .string("thread"), "turn": .object([
            "id": .string("turn"), "status": .string("completed")])]), method: "turn/completed"))
        let snapshot = ConversationProjection.project(live)
        #expect(snapshot.items.map(\.id).contains("published-visual-publication"))
        #expect(snapshot.messages.isEmpty)
        #expect(!snapshot.items.contains { if case .turnOutcome = $0 { true } else { false } })
        #expect(snapshot.forkableMessageIDs.isEmpty)
        var historical = ConversationState(conversationID: live.conversationID, threadID: "thread")
        historical.merge(history(items: [item], status: .completed))
        #expect(ConversationProjection.project(historical).items.map(\.id) == snapshot.items.map(\.id))
        let stored = try JSONEncoder().encode(live.checkpoint)
        var restored = ConversationState(conversationID: live.conversationID, threadID: "thread")
        restored.restore(try JSONDecoder().decode(ConversationState.Checkpoint.self, from: stored))
        #expect(ConversationProjection.project(restored).items.map(\.id) == snapshot.items.map(\.id))
    }

    @Test func onlyCompletedStandaloneAssistantPlacementReplacesTheAutomaticRow() throws {
        let item = try publication("mcpToolCall")
        let cases = [(embed, true), ("  " + embed, true), ("    " + embed, true),
                     ("```markdown\n\(embed)\n```", false), ("~~~~\n\(embed)\n~~~~", false),
                     ("See \(embed) here", false), ("[Chart](rc-visual:\(digest))", false),
                     ("rc-visual:\(digest)", false), ("![Chart](rc-visual:abc)", false),
                     ("![a[b](rc-visual:\(digest))", false), ("![a[b]](rc-visual:\(digest))", true)]
        for (text, placed) in cases {
            var state = ConversationState(conversationID: UUID(), threadID: "thread")
            state.apply(try event("item/completed", item: item, ordinal: 1))
            let answer = CodexAppServerV2.ThreadItem.agentMessage(id: "answer", text: text)
            state.apply(try event("item/started", item: answer, ordinal: 2))
            var memo = ConversationProjection.Memo()
            #expect(ConversationProjection.project(state, memo: &memo).items.map(\.id).contains("published-visual-publication"))
            state.apply(try event("item/completed", item: answer, ordinal: 2))
            let snapshot = ConversationProjection.project(state, memo: &memo)
            #expect(snapshot.items.map(\.id).contains("published-visual-publication") == !placed)
            #expect(snapshot.messages.first?.text == text)
        }
        var userExample = ConversationState(conversationID: UUID(), threadID: "thread")
        userExample.merge(history(items: [.userMessage(id: "user", content: [.text(text: embed, textElements: [])]), item]))
        #expect(ConversationProjection.project(userExample).items.map(\.id).contains("published-visual-publication"))
    }

    @Test func publicationMetadataValidatesTheReferenceAtDecodeAndSurvivesReencoding() throws {
        for type in ["mcpToolCall", "dynamicToolCall"] {
            let item = try publication(type)
            #expect(item.publishedVisual?.reference.digest == digest)
            #expect(item.publishedVisual?.title == "Chart")
            let encoded = try JSONEncoder().encode(item)
            #expect(try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: encoded) == item)
            let malformed = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            var wrong = try #require(malformed)
            wrong["rcVisual"] = ["digest": "not-a-digest", "title": "Chart"]
            let badData = try JSONSerialization.data(withJSONObject: wrong)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: badData)
            }
        }
    }

    @Test func placementInAnotherTurnCannotHideANewPublication() throws {
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(items: [.agentMessage(id: "prior", text: embed)], turnID: "prior"))
        state.apply(try event("item/completed", item: publication("dynamicToolCall"), ordinal: 1))
        #expect(ConversationProjection.project(state).items.map(\.id).contains("published-visual-publication"))
    }

    @Test(arguments: ["mcpToolCall", "dynamicToolCall"], ["👩‍💻 Plan", "\u{FEFF}"])
    func publisherTitlesSurviveWithoutClientRevalidation(type: String, title: String) throws {
        let item = try publication(type, title: title)
        #expect(item.publishedVisual?.title == title)
        let encoded = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: encoded) == item)
    }

    @Test(arguments: ["mcpToolCall", "dynamicToolCall"])
    func sameTitleRevisionReplacesOnlyItsEarlierAutomaticRow(type: String) throws {
        let draft = try publication(type, id: "draft")
        let fixed = try publication(type, id: "fixed", referenceDigest: String(repeating: "b", count: 64))
        let other = try publication(type, id: "other", title: "Other")
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        state.merge(history(items: [draft, fixed, other], status: .completed))
        let rows = ConversationProjection.project(state).items.map(\.id)
        #expect(!rows.contains("published-visual-draft"))
        #expect(rows.contains("published-visual-fixed"))
        #expect(rows.contains("published-visual-other"))
        state.apply(try event("item/completed", item: .agentMessage(id: "answer", text: embed), ordinal: 4))
        let reused = ConversationProjection.project(state)
        #expect(reused.messages.contains { $0.text == embed })
        #expect(reused.items.map(\.id).contains("published-visual-fixed"))
        state.apply(try event("item/completed", item: .agentMessage(id: "answer", text:
            "![Fixed](rc-visual:\(String(repeating: "b", count: 64)))"), ordinal: 4))
        let placed = ConversationProjection.project(state).items.map(\.id)
        #expect(!placed.contains("published-visual-fixed"))
        #expect(!placed.contains("published-visual-draft"))
        #expect(placed.contains("published-visual-other"))
    }
}
