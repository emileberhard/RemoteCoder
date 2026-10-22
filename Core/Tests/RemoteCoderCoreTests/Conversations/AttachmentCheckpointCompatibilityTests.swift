import Foundation
import Testing
@testable import RemoteCoderCore

struct AttachmentCheckpointCompatibilityTests {
    @Test func frozenMainCheckpointKeepsUnmarkedTextAndAbsentAttachments() throws {
        let checkpoint = try JSONDecoder().decode(ConversationState.Checkpoint.self,
                                                  from: ProtocolFixtures.data(at: "checkpoints/main-9db89687.json"))
        let message = try #require(checkpoint.submissions.values.first?.message)
        #expect(message.text == "Attachment 1:\n```\nHistorical unmarked paste\n```")
        #expect(message.attachments.isEmpty)
        var restored = ConversationState(conversationID: UUID(), threadID: "compat-main")
        restored.restore(checkpoint)
        #expect(ConversationProjection.project(restored).messages.first?.text == message.text)
        #expect(ConversationProjection.project(restored).messages.first?.attachments.isEmpty == true)
    }

    @Test func newCheckpointPreservesAttachmentOrderAndOriginalBody() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let imageID = try #require(UUID(uuidString: "77777777-2222-3333-4444-555555555555"))
        let image = CodexImageAttachment(id: imageID, data: Data("ABC".utf8), format: .png,
                                        pixelSize: CodexImagePixelSize(width: 1, height: 1))
        let attachments = [
            MessageAttachment(id: id, content: .text("Exact pasted text\nsecond line")),
            MessageAttachment(id: imageID, content: .imageData(image)),
            MessageAttachment(id: ChatMessage.deterministicID(for: "file:/host/uploads/report.txt"),
                              content: .file(UploadedFile(path: "/host/uploads/report.txt", bytes: 3, sha256: "abc"))),
            MessageAttachment(id: ChatMessage.deterministicID(for: "file:/host/uploads/unknown.txt"),
                              content: .fileReference(path: "/host/uploads/unknown.txt")),
        ]
        let message = ChatMessage(id: id, role: .user, text: "Typed body", attachments: attachments,
                                  date: Date(timeIntervalSinceReferenceDate: 0))
        var state = ConversationState(conversationID: id, threadID: "compat-main")
        state.submit(message)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state.checkpoint)
        let checkpoint = try JSONDecoder().decode(ConversationState.Checkpoint.self, from: data)
        #expect(checkpoint.submissions[id]?.message == message)
        var restored = ConversationState(conversationID: id, threadID: "compat-main")
        restored.restore(checkpoint)
        #expect(ConversationProjection.project(restored).messages.first?.text == "Typed body")
        #expect(ConversationProjection.project(restored).messages.first?.attachments == attachments)
        let legacy = try JSONDecoder().decode(MainMessageFields.self, from: encoder.encode(message))
        #expect(legacy.text == "Typed body\n\nExact pasted text\nsecond line\n\nFile attachment: /host/uploads/unknown.txt")
        #expect(legacy.imageAttachments == [image])
        #expect(legacy.fileAttachments.map(\.path) == ["/host/uploads/report.txt"])
    }

    @Test func draftsSavedWithInlineImagesStillDecodeAndWaitForUpload() throws {
        let json = #"""
        {"id":"77777777-2222-3333-4444-555555555555","content":{"image":{"_0":{"id":"77777777-2222-3333-4444-555555555555",
        "data":"QUJD","format":"png","pixelSize":{"width":1,"height":1}}}}}
        """#
        let attachment = try JSONDecoder().decode(ComposerAttachment.self, from: Data(json.utf8))
        guard case .legacyImage(let image) = attachment.content else { Issue.record("Expected the saved inline image"); return }
        #expect(image.data == Data("ABC".utf8))
        #expect(image.fileName == "image-77777777-2222-3333-4444-555555555555.png")
        #expect(!attachment.isReadyToSend)
    }

    @Test func firstNonemptyLineProvidesThePreview() {
        let attachment = MessageAttachment(id: UUID(), content: .text("\n  \n First line stays intact.\nSecond line stays in the viewer."))
        #expect(attachment.preview == "First line stays intact.")
        #expect(attachment.detail == "4 lines")
    }

    @Test func frozenInlineCheckpointRestoresOrderAndDegradesToReadableText() throws {
        let checkpoint = try JSONDecoder().decode(ConversationState.Checkpoint.self,
            from: ProtocolFixtures.data(at: "checkpoints/inline-pasted-text-v2.json"))
        let message = try #require(checkpoint.submissions.values.first?.message)
        let content = try #require(message.inlineContent)
        #expect(content.plainText == "before Exact pasted text\nsecond line after")
        #expect(content.document.pasted.first?.id == message.attachments.first?.id)
        #expect(UserMessageText(checkpoint.submissions.values.first?.input ?? "").inline == content.document)
        var restored = ConversationState(conversationID: UUID(), threadID: "compat-inline")
        restored.restore(checkpoint)
        #expect(ConversationProjection.project(restored).messages.first?.inlineContent == content)
        let encoder = JSONEncoder()
        let current = try JSONDecoder().decode(ChatMessage.self, from: encoder.encode(message))
        #expect(current == message)
        let legacy = try JSONDecoder().decode(MainMessageFields.self, from: encoder.encode(message))
        #expect(legacy.text == "before Exact pasted text\nsecond line after\n\nFile attachment: /host/uploads/unknown.txt")
        #expect(legacy.imageAttachments.count == 1)
        #expect(legacy.fileAttachments.count == 1)
    }

    @Test func frozenLiteralCheckpointKeepsTypedMarkersAndOrderedPaste() throws {
        let checkpoint = try JSONDecoder().decode(ConversationState.Checkpoint.self,
            from: ProtocolFixtures.data(at: "checkpoints/inline-literal-text-v2.json"))
        let submission = try #require(checkpoint.submissions.values.first)
        let content = try #require(submission.message.inlineContent)
        #expect(UserMessageText(submission.input).inline == content.document)
        #expect(content.document.pasted.count == 1)
        #expect(content.document.pasted.first?.text == "本当の paste 😀")
        #expect(content.plainText.hasPrefix("<remotecoder_pasted_text_v1>"))
        #expect(content.plainText.hasSuffix("</remotecoder_pasted_text_v2>"))
        let encoded = try JSONEncoder().encode(submission.message)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: encoded).inlineContent == content)
        let legacy = try JSONDecoder().decode(MainMessageFields.self, from: encoded)
        #expect(legacy.text == content.plainText + "\n\nFile attachment: /host/uploads/unknown.txt")
    }

    @Test func storedPresentationFieldsCannotOverrideAuthoritativeText() throws {
        let data = Data(#"{"id":"11111111-2222-3333-4444-555555555555","content":{"text":{"_0":"First line\nsecond line"}},"preview":"Stale preview","detail":"99 lines","revision":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        let attachment = try JSONDecoder().decode(MessageAttachment.self, from: data)
        #expect(attachment.preview == "First line")
        #expect(attachment.detail == "2 lines")
        #expect(attachment == MessageAttachment(id: attachment.id, content: .text("First line\nsecond line")))
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(attachment))
        #expect(encoded.objectValue?.keys.sorted() == ["content", "id"])
    }

    @Test func coldCheckpointStoreLoadsTheOldEnvelopeAndRetainsNewAttachments() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldID = UUID()
        let old = try JSONDecoder().decode(JSONValue.self, from: ProtocolFixtures.data(at: "checkpoints/main-9db89687.json"))
        let envelope = JSONValue.object(["containsLocalRecords": .bool(true), "checkpoint": old])
        try JSONEncoder().encode(envelope).write(to: directory.appending(path: "\(oldID).json"))
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let loaded = try #require(try await store.load(oldID))
        #expect(loaded.submissions.values.first?.message.attachments.isEmpty == true)

        let current = try JSONDecoder().decode(ConversationState.Checkpoint.self,
                                               from: ProtocolFixtures.data(at: "checkpoints/sent-attachments-v1.json"))
        #expect(current.submissions.values.first?.message.attachments.first?.preview == "Exact pasted text")
        let currentID = UUID()
        try await store.save(current, conversationID: currentID)
        let cold = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        let reloaded = try #require(try await cold.load(currentID))
        #expect(reloaded.submissions.values.first?.message == current.submissions.values.first?.message)
        #expect(reloaded.submissions.values.first?.message.attachments.count == 4)
        #expect(reloaded.submissions.values.first?.message.text == "Typed body")
    }

    private struct MainMessageFields: Decodable {
        let text: String
        let imageAttachments: [CodexImageAttachment]
        let fileAttachments: [UploadedFile]
    }
}
