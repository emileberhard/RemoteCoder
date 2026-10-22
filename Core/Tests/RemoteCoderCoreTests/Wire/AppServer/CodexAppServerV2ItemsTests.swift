import Foundation
import Testing

@testable import RemoteCoderCore

struct CodexAppServerV2ItemsTests {
    @Test func collabAgentToolsDecodeCurrentAndFutureValues() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        #expect(
            try decoder.decode(
                CodexAppServerV2.CollabAgentTool.self,
                from: Data(#""sendMessage""#.utf8)
            ) == "sendMessage"
        )
        #expect(
            try decoder.decode(
                CodexAppServerV2.CollabAgentTool.self,
                from: Data(#""futureTool""#.utf8)
            ) == "futureTool"
        )
        #expect(
            try encoder.encode(CodexAppServerV2.CollabAgentTool("futureTool"))
                == Data(#""futureTool""#.utf8)
        )
    }

    @Test func asyncQuestionMessagesDecodeRoundTripAndTolerateLegacyRecords() throws {
        // The exact shape `request_user_input_async` emits: the item id is the tool call id.
        let wire = #"""
        {"type":"agentMessage","id":"call_q1","text":"Which database?\n- Postgres\n- SQLite\n\nAnything else?",
         "phase":"final_answer","delivery":"async",
         "questions":[{"title":"Which database?","options":["Postgres","SQLite"]},{"title":"Anything else?"}]}
        """#
        let item = try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: Data(wire.utf8))
        guard case .agentMessage(let id, let text, let phase, let delivery, let questions) = item else {
            Issue.record("Expected an agent message"); return
        }
        #expect(id == "call_q1")
        #expect(text.hasPrefix("Which database?"))
        #expect(phase == .finalAnswer)
        #expect(delivery == .async)
        #expect(questions == [
            .init(title: "Which database?", options: ["Postgres", "SQLite"]),
            .init(title: "Anything else?", options: nil),
        ])
        #expect(item.asyncQuestions?.count == 2)

        let encoded = try JSONEncoder().encode(item)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["delivery"] as? String == "async")
        #expect(object["phase"] as? String == "final_answer")
        let restored = try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: encoded)
        #expect(restored.asyncQuestions == questions)

        // Checkpoints written before these fields existed, and plain replies, keep decoding.
        let legacy = try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self,
            from: Data(#"{"type":"agentMessage","id":"m1","text":"Done"}"#.utf8))
        guard case .agentMessage(_, _, let legacyPhase, let legacyDelivery, let legacyQuestions) = legacy else {
            Issue.record("Expected an agent message"); return
        }
        #expect(legacyPhase == nil && legacyDelivery == nil && legacyQuestions == nil)
        #expect(legacy.asyncQuestions == nil)
        let legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(legacyObject["delivery"] == nil && legacyObject["questions"] == nil && legacyObject["phase"] == nil)

        // A future phase or delivery value must not drop the whole item.
        let future = try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self,
            from: Data(#"{"type":"agentMessage","id":"m2","text":"Soon","phase":"preamble","delivery":"deferred"}"#.utf8))
        guard case .agentMessage(_, _, let futurePhase, let futureDelivery, _) = future else {
            Issue.record("Expected an agent message"); return
        }
        #expect(futurePhase == CodexAppServerV2.AgentMessagePhase(rawValue: "preamble"))
        #expect(futureDelivery == CodexAppServerV2.AgentMessageDelivery(rawValue: "deferred"))
        #expect(future.asyncQuestions == nil)
    }

    @Test func userMessageImagesDecodeInlineAndFileReferences() throws {
        let wire = #"""
        {"type":"userMessage","id":"u1","content":[
         {"type":"image","url":"data:image/png;base64,AAAA"},
         {"type":"image","fileId":"file_123","detail":"high"}]}
        """#
        let item = try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: Data(wire.utf8))
        guard case .userMessage(_, let content, _) = item,
              content.count == 2,
              case .image(let inline) = content[0],
              case .image(let file) = content[1]
        else {
            Issue.record("Expected a user message with two images"); return
        }
        #expect(inline == .inline(url: "data:image/png;base64,AAAA"))
        #expect(file == .file(id: "file_123"))

        let encoded = try JSONEncoder().encode(CodexAppServerV2.UserInput.image(.file(id: "file_123")))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(object == ["type": "image", "fileId": "file_123"])
    }

    @Test func collabAgentStatusesDecodeInterruptedAndFutureValues() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        #expect(
            try decoder.decode(
                CodexAppServerV2.CollabAgentToolCallStatus.self,
                from: Data(#""interrupted""#.utf8)
            ) == .interrupted
        )
        #expect(
            try decoder.decode(
                CodexAppServerV2.CollabAgentToolCallStatus.self,
                from: Data(#""futureStatus""#.utf8)
            ) == CodexAppServerV2.CollabAgentToolCallStatus(rawValue: "futureStatus")
        )
        #expect(
            try encoder.encode(CodexAppServerV2.CollabAgentToolCallStatus.interrupted)
                == Data(#""interrupted""#.utf8)
        )
    }

    @Test func nativeActivityRetainsChildIdentityAndRoundTrips() throws {
        let data = Data(#"{"type":"subAgentActivity","id":"item","kind":"interrupted","agentThreadId":"child","agentPath":"/root/review"}"#.utf8)
        let item = try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: data)
        #expect(item == .subAgentActivity(id: "item", kind: "interrupted", agentThreadId: "child", agentPath: "/root/review"))
        #expect(try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: JSONEncoder().encode(item)) == item)
    }
}
