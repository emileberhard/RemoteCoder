import Foundation
import SwiftData

@Model
final class ComposerDraft {
    @Attribute(.unique) var destination: String
    var id: UUID
    var text: String
    @Attribute(.codable, .externalStorage) var attachments: [ComposerAttachment]
    var revision: Int
    @Attribute(.codable, .externalStorage) var documentContent: ComposerDocumentContent?
    var modifiedAt: Date?
    @Attribute(.codable) var newChat: NewChatSetup?
    @Transient var document: ComposerDocument?
    @Transient var isDiscarded = false

    init(destination: String) {
        self.destination = destination
        id = UUID()
        text = ""
        attachments = []
        revision = 0
        documentContent = nil
        modifiedAt = nil
        newChat = nil
        document = nil
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
