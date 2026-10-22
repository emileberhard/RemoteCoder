import Foundation
import Testing

@testable import RemoteCoderCore

struct CodexCheckpointItemsFixtureTests {
    private let storedItems = #"""
    [
      {"type":"userMessage","id":"u","content":[{"type":"text","text":"hello"}],"clientId":"client-u"},
      {"type":"hookPrompt","id":"h","fragments":[{"hookRunId":"run","text":"hook"}]},
      {"type":"agentMessage","id":"a","text":"answer","phase":"final_answer","delivery":"async","questions":[{"title":"Choose","options":["A","B"]}]},
      {"type":"plan","id":"p","text":"plan"},
      {"type":"reasoning","id":"r","summary":["summary"],"content":["detail"]},
      {"type":"commandExecution","id":"c","command":"pwd","cwd":"/repo","status":"completed","commandActions":[],"aggregatedOutput":"/repo","exitCode":0,"durationMs":12},
      {"type":"fileChange","id":"f","changes":[{"path":"a.swift","kind":{"type":"add"},"diff":"+a"}],"status":"completed"},
      {"type":"mcpToolCall","id":"m","server":"files","tool":"read","status":"completed","arguments":{},"result":{"content":[]}},
      {"type":"dynamicToolCall","id":"d","tool":"run","status":"completed","arguments":{},"success":true,"contentItems":[]},
      {"type":"subAgentActivity","id":"s","kind":"started","agentThreadId":"child","agentPath":"/root/child"},
      {"type":"collabAgentToolCall","id":"l","tool":"sendMessage","status":"completed","senderThreadId":"parent","receiverThreadIds":["child"],"prompt":"check","agentsStates":{"child":{"status":"running"}}},
      {"type":"webSearch","id":"w","query":"Swift","action":{"type":"search","query":"Swift"}},
      {"type":"imageView","id":"v","path":"/tmp/image.png","rcMedia":[{"path":"/media/abc.png","mimeType":"image/png"}]},
      {"type":"imageGeneration","id":"g","status":"completed","result":"image","revisedPrompt":"sky","savedPath":"/tmp/sky.png"},
      {"type":"enteredReviewMode","id":"e","review":"review"},
      {"type":"exitedReviewMode","id":"x","review":"done"},
      {"type":"contextCompaction","id":"k"},
      {"type":"futureItem","id":"z","mystery":true}
    ]
    """#

    @Test func checkpointItemsKeepTheirStoredJSONShapes() throws {
        let decoder = JSONDecoder()
        let items = try decoder.decode([CodexAppServerV2.ThreadItem].self, from: Data(storedItems.utf8))
        #expect(items.count == 18)
        #expect(items.map(\.id) == ["u", "h", "a", "p", "r", "c", "f", "m", "d", "s", "l", "w", "v", "g", "e", "x", "k", "z"])
    }

    @Test func checkpointItemsDecodeToTheirStoredValues() throws {
        let items = try JSONDecoder().decode([CodexAppServerV2.ThreadItem].self, from: Data(storedItems.utf8))
        let expected: [CodexAppServerV2.ThreadItem] = [
            .userMessage(id: "u", content: [.text(text: "hello", textElements: [])], clientId: "client-u"),
            .hookPrompt(id: "h", fragments: [.init(text: "hook")]),
            .agentMessage(id: "a", text: "answer", phase: .finalAnswer, delivery: .async,
                          questions: [.init(title: "Choose", options: ["A", "B"])]),
            .plan(id: "p", text: "plan"),
            .reasoning(id: "r", summary: ["summary"], content: ["detail"]),
            .commandExecution(id: "c", command: "pwd", cwd: "/repo", status: .completed, commandActions: [],
                              aggregatedOutput: "/repo", exitCode: 0, durationMs: 12),
            .fileChange(id: "f", changes: [.init(path: "a.swift", kind: .add)], status: .completed),
            .mcpToolCall(id: "m", server: "files", tool: "read", status: .completed, arguments: .object([:]),
                         result: .init(structuredContent: nil), error: nil, durationMs: nil, media: []),
            .dynamicToolCall(id: "d", namespace: nil, tool: "run", status: .completed, arguments: .object([:]),
                             success: true, contentItems: [], durationMs: nil, media: []),
            .subAgentActivity(id: "s", kind: "started", agentThreadId: "child", agentPath: "/root/child"),
            .collabAgentToolCall(id: "l", tool: "sendMessage", status: .completed, receiverThreadIds: ["child"], prompt: "check"),
            .webSearch(id: "w", query: "Swift", action: .object(["type": .string("search"), "query": .string("Swift")])),
            .imageView(id: "v", path: "/tmp/image.png", image: .init(path: "/media/abc.png", mimeType: "image/png")),
            .imageGeneration(id: "g", status: "completed", result: "image", revisedPrompt: "sky", savedPath: "/tmp/sky.png"),
            .enteredReviewMode(id: "e", review: "review"),
            .exitedReviewMode(id: "x", review: "done"),
            .contextCompaction(id: "k"),
            .unknown(id: "z", type: "futureItem",
                     payload: .object(["type": .string("futureItem"), "id": .string("z"), "mystery": .bool(true)])),
        ]
        #expect(items == expected)
    }

    @Test func checkpointItemsSurviveARewriteAndReload() throws {
        let items = try JSONDecoder().decode([CodexAppServerV2.ThreadItem].self, from: Data(storedItems.utf8))
        let rewritten = try JSONEncoder().encode(items)
        #expect(try JSONDecoder().decode([CodexAppServerV2.ThreadItem].self, from: rewritten) == items)
    }

    @Test func toolMediaSurvivesACheckpointRewrite() throws {
        let stored = Data(#"{"type":"dynamicToolCall","id":"d","tool":"Read","status":"completed","arguments":{},"rcMedia":[{"path":"/tmp/a.pdf","mimeType":"application/pdf","name":"a.pdf"}]}"#.utf8)
        let item = try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: stored)
        #expect(item.toolMedia?.tool == "Read")
        #expect(item.toolMedia?.media == [.init(path: "/tmp/a.pdf", mimeType: "application/pdf", name: "a.pdf")])
        #expect(try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: JSONEncoder().encode(item)) == item)
    }

    @Test func anImageViewStoredWithoutItsPathStaysUnknown() throws {
        let stored = Data(#"{"type":"imageView","id":"v"}"#.utf8)
        let item = try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: stored)
        #expect(item == .unknown(id: "v", type: "imageView",
                                 payload: .object(["type": .string("imageView"), "id": .string("v")])))
        #expect(try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: JSONEncoder().encode(item)) == item)
    }

    @Test func aReasoningItemWithoutStoredPartsDecodesEmpty() throws {
        let item = try JSONDecoder().decode(CodexAppServerV2.ThreadItem.self, from: Data(#"{"type":"reasoning","id":"r"}"#.utf8))
        #expect(item == .reasoning(id: "r", summary: [], content: []))
    }
}
