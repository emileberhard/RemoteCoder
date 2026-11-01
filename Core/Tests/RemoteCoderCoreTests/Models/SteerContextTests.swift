import Foundation
import Testing
@testable import RemoteCoderCore

struct SteerContextTests {
    @Test
    func recordsTheOutputAtSendAndKeepsOnlyAWholeWordTail() {
        let text = String(repeating: "older ", count: 200) + "the last visible words"
        let note = SteerContext.note(shownText: text)
        #expect(note.hasSuffix("the last visible words\". They had not seen anything you wrote after that."))
        let excerpt = note.components(separatedBy: "\"…")[1].components(separatedBy: "\"")[0]
        #expect(excerpt.count <= 600)
        #expect(excerpt.hasPrefix("older "))
        #expect(!note.contains(text))
        let unbroken = SteerContext.note(shownText: String(repeating: "x", count: 900))
        #expect(unbroken.contains("\"…" + String(repeating: "x", count: 600) + "\""))
    }

    @Test
    func noOutputBelongsToTheRunningTurnEvenWhenOlderRepliesExist() {
        let old = ChatMessage(role: .codex, text: "Earlier reply", canonicalTurnID: "old")
        #expect(SteerContext.capture(in: [.message(old)], turnID: "running", renderedSource: { $0.text }) ==
            "RemoteCoder note: the user sent their latest message while your turn was still running. When they sent it, they had not yet seen any of your output from this turn.")
    }

    @Test
    func capturesLiveRenderInsteadOfTheStreamingRowsOldValue() {
        let first = ChatMessage(role: .codex, text: "Earlier commentary", canonicalTurnID: "running")
        let streaming = ChatMessage(role: .codex, text: "stale", canonicalTurnID: "turn-running", isStreaming: true)
        let items: [ChatStreamItem] = [.message(first), .message(streaming), .message(ChatMessage(role: .user, text: "steer"))]
        let note = SteerContext.capture(in: items, turnID: "running") {
            $0.markdownSource(renderedText: "the words already on screen")
        }
        #expect(note.contains("\"…the words already on screen\""))
        #expect(!note.contains("stale"))
        #expect(first.markdownSource(renderedText: "unrelated cached render") == "Earlier commentary")
        #expect(SteerContext.note(shownText: "Visible") ==
            "RemoteCoder note: the user sent their latest message while your turn was still running. When they sent it, the last of your output on their screen ended with: \"…Visible\". They had not seen anything you wrote after that.")
    }
}
