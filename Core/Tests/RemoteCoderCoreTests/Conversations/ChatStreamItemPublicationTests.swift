import Foundation
import Testing
@testable import RemoteCoderCore

struct ChatStreamItemPublicationTests {
    private let prompt = ChatStreamItem.message(ChatMessage(role: .user, text: "Explain"))
    private let replyID = UUID()

    private func reply(_ text: String, isStreaming: Bool = true) -> ChatStreamItem {
        .message(ChatMessage(id: replyID, role: .codex, text: text, date: Date(timeIntervalSince1970: 1), isStreaming: isStreaming))
    }

    @Test func streamingTextGrowthAloneIsNotARowChange() {
        #expect([prompt, reply("Hello, wor")].differsOnlyInStreamingText(from: [prompt, reply("Hello")]))
    }

    @Test func completingTheStreamIsARowChange() {
        #expect(![prompt, reply("Hello, world", isStreaming: false)].differsOnlyInStreamingText(from: [prompt, reply("Hello")]))
    }

    @Test func settledTextChangesAreRowChanges() {
        let edited = ChatStreamItem.message(ChatMessage(role: .user, text: "Explain more"))
        #expect(![edited, reply("Hello")].differsOnlyInStreamingText(from: [prompt, reply("Hello")]))
        #expect(![prompt, reply("Hello!", isStreaming: false)]
            .differsOnlyInStreamingText(from: [prompt, reply("Hello", isStreaming: false)]))
    }

    @Test func membershipAndOtherStreamingFieldsAreRowChanges() {
        let edge = ChatStreamItem.historyEdge(HistoryEdge(kind: .older, cursor: "c1"))
        #expect(![edge, prompt, reply("Hello")].differsOnlyInStreamingText(from: [prompt, reply("Hello")]))
        guard case .message(var steered) = reply("Hello, wor") else { return }
        steered.delivery = .steered
        #expect(![prompt, .message(steered)].differsOnlyInStreamingText(from: [prompt, reply("Hello")]))
    }
}
