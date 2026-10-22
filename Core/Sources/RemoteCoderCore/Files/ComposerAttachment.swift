import Foundation

struct ComposerAttachment: Identifiable, Sendable, Codable, Equatable {
    enum Content: Sendable, Codable, Equatable {
        case text(String)
        case legacyImage(CodexImageAttachment)
        case file(ComposerFileAttachment)

        private enum CodingKeys: String, CodingKey {
            case text
            case legacyImage = "image"
            case file
        }
    }

    let id: UUID
    let content: Content

    static func text(_ text: String) -> ComposerAttachment {
        ComposerAttachment(id: UUID(), content: .text(text))
    }

    static func file(_ file: ComposerFileAttachment) -> ComposerAttachment {
        ComposerAttachment(id: file.id, content: .file(file))
    }

    var text: String? {
        switch content {
        case .text(let value):
            return value
        case .legacyImage, .file:
            return nil
        }
    }

    var file: ComposerFileAttachment? {
        switch content {
        case .file(let value):
            return value
        case .text, .legacyImage:
            return nil
        }
    }

    var isReadyToSend: Bool {
        switch content {
        case .text: true
        case .file(let file): file.uploaded != nil
        case .legacyImage: false
        }
    }
}
