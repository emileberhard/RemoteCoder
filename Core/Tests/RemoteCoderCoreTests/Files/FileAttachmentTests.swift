import Foundation
import Testing
@testable import RemoteCoderCore

private struct AttachedFilesFixture: Decodable {
    struct Entry: Decodable {
        let name: String
        let body: String
        let paths: [String]
        let block: String
        let message: String
    }

    let cases: [Entry]
}

struct FileAttachmentTests {
    /// The block is the whole provider handoff, and `remotecoder_tools/probes.py`
    /// sends the same bytes in its live probe.
    @Test func promptBlockMatchesTheSharedFixture() throws {
        let fixture = try JSONDecoder().decode(AttachedFilesFixture.self, from: ProtocolFixtures.data(named: "attached-files-block"))
        #expect(!fixture.cases.isEmpty)
        for entry in fixture.cases {
            #expect(AttachedFilesPromptBlock.render(entry.paths) == entry.block, "\(entry.name): block")
            #expect(AttachedFilesPromptBlock.append(to: entry.body, paths: entry.paths) == entry.message, "\(entry.name): message")
        }
    }

    @Test func messagesSavedBeforeFileAttachmentsAndStreamingStillDecode() throws {
        let legacy = """
        {"id":"7B2D2C4E-4B2E-4E5B-9C3C-1C7C8E1F2A3B","role":"user","text":"hello",
         "imageAttachments":[],"date":0,"wasSteered":false}
        """
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
        #expect(message.attachments.isEmpty)
        #expect(!message.isStreaming)

        let stored = UploadedFile(path: "/Users/developer/.remote-coder/uploads/abc/report.pdf", bytes: 42, sha256: "ff")
        let withFile = ChatMessage(role: .user, text: "read it", fileAttachments: [stored],
                                   isStreaming: true)
        let roundTripped = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(withFile))
        if case .file(let file) = roundTripped.attachments.first?.content { #expect(file == stored) }
        else { Issue.record("Uploaded file metadata must survive the checkpoint") }
        #expect(roundTripped.isStreaming)
        #expect(stored.name == "report.pdf")
    }

    @Test func stagingCopiesThePickedFileUnderTheAttachmentID() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "upload-staging-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "picked").appending(path: "Q3 report.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("twelve bytes".utf8).write(to: source)
        let staging = UploadStaging(directory: root.appending(path: "staging"))
        let id = UUID()

        let staged = try await staging.prepare(source, id: id)
        let attachment = ComposerFileAttachment(id: id, name: "Q3 report.txt", byteCount: staged.byteCount,
                                                placement: .staged(fileName: staged.fileName))

        #expect(staged == UploadStaging.StagedFile(fileName: "Q3 report.txt", byteCount: 12))
        let copy = try #require(staging.url(for: attachment))
        #expect(try Data(contentsOf: copy) == Data("twelve bytes".utf8))
        staging.remove(id: id)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        var uploaded = attachment
        uploaded.placement = .uploaded(UploadedFile(path: "/host/Q3-report.txt", bytes: 12, sha256: "00"))
        #expect(staging.url(for: uploaded) == nil)
    }
}
