import Foundation
import Testing
@testable import RemoteCoderCore

struct SentPromptRecallTests {
    @Test func recallsTheNewestPromptPastAgentRepliesAndQuestionAnswers() {
        let items: [ChatStreamItem] = [
            user("First prompt"),
            .message(ChatMessage(role: .codex, text: "First answer")),
            user("Second prompt\nwith a second line"),
            .message(ChatMessage(role: .codex, text: "Which file?")),
            .message(ChatMessage(role: .user, text: "README.md",
                                 questionReplies: [QuestionReply(question: "Which file?", answer: "README.md")])),
        ]

        #expect(SentPromptRecall.lastPrompt(in: items)?.expandedText == "Second prompt\nwith a second line")
    }

    @Test func attachmentOnlyPromptRecallsNothingRatherThanAnOlderPrompt() {
        #expect(SentPromptRecall.lastPrompt(in: [user("Older prompt"), user(ChatMessage.imageAttachmentText)]) == nil)
        #expect(SentPromptRecall.lastPrompt(in: [user("Older prompt"), user(ChatMessage.fileAttachmentText)]) == nil)
    }

    @Test func unloadedHistoryRecallsNothing() {
        let olderEdge = ChatStreamItem.historyEdge(HistoryEdge(kind: .older, cursor: "c1"))
        let newerEdge = ChatStreamItem.historyEdge(HistoryEdge(kind: .newer, cursor: "c2"))
        let reply = ChatStreamItem.message(ChatMessage(role: .codex, text: "Done"))

        #expect(SentPromptRecall.lastPrompt(in: [olderEdge, reply]) == nil)
        #expect(SentPromptRecall.lastPrompt(in: [user("Visible prompt"), newerEdge]) == nil)
        #expect(SentPromptRecall.lastPrompt(in: []) == nil)
    }

    @Test func inlineRecallRetainsPasteIdentityAndLegacyRecallExpandsText() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let content = ComposerDocumentContent(runs: [.text("before "), .paste(.init(id: id, text: "full paste")), .text(" after")])
        let inline = ChatMessage(role: .user, text: "before  after", inlineContent: InlineMessageContent(content))
        #expect(SentPromptRecall.lastPrompt(in: [.message(inline)]) == content)
        let legacy = ChatMessage(role: .user, text: "caption",
            attachments: [MessageAttachment(id: id, content: .text("full paste"))])
        #expect(SentPromptRecall.lastPrompt(in: [.message(legacy)])?.runs == [.text("caption\n\nfull paste")])
    }

    @Test func filesPreserveDocumentEdgesThroughHistoryAndRecall() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let paths = ["/host/uploads/report.txt"]
        for ending in [" after  \r\n", " after  \r", " after  \n", " after  "] {
            for content in [
                ComposerDocumentContent(runs: [.text("    before\r\n"), .paste(.init(id: id, text: "pasted text")), .text(ending)]),
                ComposerDocumentContent(runs: [.text("    short indented paste\r\n" + ending)]),
            ] {
                let prompt = AttachedFilesPromptBlock.append(to: content.prompt, paths: paths)
                #expect(AttachedFilesPromptBlock.parse(prompt)?.body == content.prompt)
                let history = UserMessageText(prompt)
                #expect(history.filePaths == paths)
                let message = ChatMessage(role: .user, text: history.body,
                    inlineContent: history.inline.map(InlineMessageContent.init))
                #expect(SentPromptRecall.lastPrompt(in: [.message(message)]) == content)
            }
        }
        #expect(AttachedFilesPromptBlock.parse(AttachedFilesPromptBlock.append(to: "", paths: paths))?.body == "")
    }

    private func user(_ text: String) -> ChatStreamItem {
        .message(ChatMessage(role: .user, text: text))
    }
}
