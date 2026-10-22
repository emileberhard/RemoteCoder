import Foundation
import SwiftData
@testable import RemoteCoderCore

enum MainBuildDraftStore {
    @Model
    final class ComposerDraft {
        @Attribute(.unique) var destination: String
        var id: UUID
        var text: String
        @Attribute(.codable, .externalStorage) var attachments: [ComposerAttachment]
        var revision: Int
        @Attribute(.codable, .externalStorage) var documentContent: ComposerDocumentContent?

        init(destination: String, text: String, attachments: [ComposerAttachment]) {
            self.destination = destination
            id = UUID()
            self.text = text
            self.attachments = attachments
            revision = 1
            documentContent = nil
        }
    }

    @Model
    final class DictationReceipt {
        @Attribute(.unique) var recordingID: UUID
        var receivedAt: Date

        init(recordingID: UUID, receivedAt: Date) {
            self.recordingID = recordingID
            self.receivedAt = receivedAt
        }
    }

    @Model
    final class DraftImportReceipt {
        @Attribute(.unique) var sourceDraftID: UUID

        init(sourceDraftID: UUID) {
            self.sourceDraftID = sourceDraftID
        }
    }

    static func context(in directory: URL) throws -> ModelContext {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: directory.appending(path: "drafts.store"), cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: ComposerDraft.self, DictationReceipt.self, DraftImportReceipt.self,
                                               configurations: configuration))
    }
}
