import Foundation
import Testing
@testable import RemoteCoderCore

struct MessageAttachmentTests: ConversationHistoryFixtures {
    @Test func typedFileBlocksStayLiteralBesideRealAttachmentsAcrossLiveHistoryAndCheckpoint() throws {
        let typed = "Typed example\n\nAttached files (uploaded to this host; use these absolute paths):\n- /private/typed-only.txt"
        for paths in [[], ["/host/uploads/real.txt"]] {
            let prompt = AttachedFilesPromptBlock.append(to: ComposerDocumentContent(runs: [.text(typed)]).prompt, paths: paths)
            let item = CodexAppServerV2.ThreadItem.userMessage(id: "user", content: [.text(text: prompt, textElements: [])])
            for thread in ["thread", "claude_thread"] {
                var live = ConversationState(conversationID: UUID(), threadID: thread)
                live.apply(try event("item/completed", item: item, ordinal: 1, threadID: thread))
                var loaded = ConversationState(conversationID: UUID(), threadID: thread)
                loaded.merge(history(items: [item], threadID: thread))
                var restored = ConversationState(conversationID: live.conversationID, threadID: thread)
                restored.restore(try JSONDecoder().decode(ConversationState.Checkpoint.self, from: JSONEncoder().encode(live.checkpoint)))
                for state in [live, loaded, restored] {
                    let message = try #require(ConversationProjection.project(state).messages.first)
                    #expect(message.text == typed)
                    #expect(message.attachments.count == paths.count)
                    if let path = paths.first {
                        guard case .fileReference(let actual) = message.attachments.first?.content else {
                            Issue.record("Only the uploaded file should become a chip")
                            continue
                        }
                        #expect(actual == path)
                    }
                }
            }
        }
    }

    @Test func inlineOrderSurvivesBothProvidersLiveHistoryAndStreamingMemoization() throws {
        let firstID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let secondID = try #require(UUID(uuidString: "77777777-2222-3333-4444-555555555555"))
        let content = ComposerDocumentContent(runs: [.text("one "), .paste(.init(id: firstID, text: "two")),
            .text(" three "), .paste(.init(id: secondID, text: "four")), .text(" five")])
        let item = CodexAppServerV2.ThreadItem.userMessage(id: "user", content: [.text(text: content.prompt, textElements: [])])
        for thread in ["thread", "claude_thread"] {
            var live = ConversationState(conversationID: UUID(), threadID: thread)
            live.apply(try event("item/completed", item: item, ordinal: 1, threadID: thread))
            var loaded = ConversationState(conversationID: UUID(), threadID: thread)
            loaded.merge(history(items: [item], threadID: thread))
            for state in [live, loaded] {
                let message = try #require(ConversationProjection.project(state).messages.first)
                #expect(message.inlineContent?.document == content)
                #expect(message.attachments.map(\.id) == [firstID, secondID])
                #expect(message.text == "one  three  five")
            }
            live.apply(try event("item/started", item: .agentMessage(id: "answer", text: ""), ordinal: 2, threadID: thread))
            var memo = ConversationProjection.Memo()
            let first = try #require(ConversationProjection.project(live, memo: &memo).messages.first?.inlineContent)
            live.apply(try GatewayEventFixture.delta("Hello", threadID: thread, turnID: "turn", itemID: "answer"))
            #expect(ConversationProjection.project(live, memo: &memo).messages.first?.inlineContent === first)
        }
    }

    @Test func attachmentTitlesUseTheCaptionOrFirstPastedLine() throws {
        let pasted = """
        <remotecoder_pasted_text_v1>
        [{"id":"77777777-2222-3333-4444-555555555555","text":"\\nFirst pasted line\\nAnother line"}]
        </remotecoder_pasted_text_v1>
        """
        let files = "\n\nAttached files (uploaded to this host; use these absolute paths):\n- /host/uploads/report.txt"
        for (prompt, expected) in [(pasted, "First pasted line"), ("Caption\nSecond caption line\n\n" + pasted + files, "Caption"), (String(files.dropFirst(2)), "report.txt")] {
            let header = try ThreadFixture.basic("thread", updatedAt: 1, preview: prompt)
            #expect(header.preview == expected)
            #expect(header.displayTitle == expected)
            #expect(ConversationSidebarProjection.title(for: header, pinnedName: "Pinned title") == "Pinned title")
            var named = header
            named.name = "Named conversation"
            #expect(named.displayTitle == "Named conversation")
        }
    }

    @Test func attachmentOnlyMessagesSurviveLiveHistoryAndCheckpoint() throws {
        let pastedID = try #require(UUID(uuidString: "77777777-2222-3333-4444-555555555555"))
        let prompt = """
        <remotecoder_pasted_text_v1>
        [{"id":"77777777-2222-3333-4444-555555555555","text":"first line\\nsecond line"}]
        </remotecoder_pasted_text_v1>

        Attached files (uploaded to this host; use these absolute paths):
        - /host/uploads/report.txt
        """
        let input: [CodexAppServerV2.UserInput] = [.text(text: prompt, textElements: []), .image(.inline(url: "data:image/png;base64,QUJD"))]
        let item = CodexAppServerV2.ThreadItem.userMessage(id: "user", content: input)
        for thread in ["thread", "claude_thread"] {
            var live = ConversationState(conversationID: UUID(), threadID: thread)
            live.apply(try event("item/completed", item: item, ordinal: 1, threadID: thread))
            var loaded = ConversationState(conversationID: UUID(), threadID: thread)
            loaded.merge(history(items: [item], threadID: thread))
            var restored = ConversationState(conversationID: live.conversationID, threadID: thread)
            restored.restore(try JSONDecoder().decode(ConversationState.Checkpoint.self, from: JSONEncoder().encode(live.checkpoint)))
            for state in [live, loaded, restored] {
                let message = try #require(ConversationProjection.project(state).messages.first)
                #expect(message.text.isEmpty)
                #expect(message.attachments.count == 3)
                #expect(message.attachments.first?.id == pastedID)
                #expect(message.attachments.first?.preview == "first line")
                #expect(message.attachments.first?.detail == "2 lines")
                if case .text(let text) = message.attachments.first?.content { #expect(text == "first line\nsecond line") }
                else { Issue.record("Pasted text must stay available to the reader") }
                if case .fileReference(let path) = message.attachments.last?.content { #expect(path == "/host/uploads/report.txt") }
                else { Issue.record("History must preserve the known file path") }
            }
        }
    }

    @Test func sharedPastedTextFixturesPreserveKnownAndUnknownHistory() throws {
        let fixtures = try JSONDecoder().decode([PastedTextFixture].self,
                                                from: ProtocolFixtures.data(at: "attachments/pasted-text-v1-cases.json"))
        for fixture in fixtures {
            var state = ConversationState(conversationID: UUID(), threadID: "thread")
            state.merge(history(items: [.userMessage(id: "user", content: [.text(text: fixture.prompt, textElements: [])])]))
            let message = try #require(ConversationProjection.project(state).messages.first)
            #expect(message.text == fixture.body, "\(fixture.name)")
            let pasted = message.attachments.filter { if case .text = $0.content { true } else { false } }
            #expect(pasted.count == (fixture.pasted ? 1 : 0), "\(fixture.name)")
            if !fixture.pasted {
                #expect(try ThreadFixture.basic("thread", updatedAt: 1, preview: fixture.prompt).preview == fixture.prompt,
                        "\(fixture.name)")
            }
        }
    }

    @Test func attachmentSummariesStayBoundedAndAreReusedWhileAnAssistantStreams() throws {
        let longWord = String(repeating: "a", count: 10_000)
        let attachment = MessageAttachment(id: UUID(), content: .text(longWord))
        #expect(attachment.preview.count <= 121)
        var state = ConversationState(conversationID: UUID(), threadID: "thread")
        let prompt = ComposerDocumentContent(runs: [.paste(.init(id: attachment.id, text: longWord))]).prompt
        state.apply(try event("item/completed", item: .userMessage(id: "user", content: [.text(text: prompt, textElements: [])]), ordinal: 1))
        state.apply(try event("item/started", item: .agentMessage(id: "answer", text: ""), ordinal: 2))
        var memo = ConversationProjection.Memo()
        let first = try #require(ConversationProjection.project(state, memo: &memo).messages.first?.attachments.first)
        state.apply(try agentDelta("Hello"))
        let second = try #require(ConversationProjection.project(state, memo: &memo).messages.first?.attachments.first)
        #expect(first === second)
    }

}

private struct PastedTextFixture: Decodable {
    let name: String
    let prompt: String
    let body: String
    let pasted: Bool
}
