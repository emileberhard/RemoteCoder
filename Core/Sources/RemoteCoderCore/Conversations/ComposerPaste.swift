import Foundation

enum ComposerPastedText: Equatable {
    case attachment(String)
    case inline(String)

    static let attachmentThreshold = 1_500

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self = trimmed.prefix(Self.attachmentThreshold).count == Self.attachmentThreshold ? .attachment(raw) : .inline(raw)
    }
}

struct ComposerPaste<Image> {
    let fileURLs: [URL]
    let images: [Image]
    let text: ComposerPastedText?

    init(fileURLs: [URL], images: @autoclosure () -> [Image], string: @autoclosure () -> String?) {
        if fileURLs.isEmpty {
            self.fileURLs = []
            self.images = images()
            text = string().flatMap(ComposerPastedText.init)
        } else {
            self.fileURLs = fileURLs
            self.images = []
            text = nil
        }
    }

    var hasAttachments: Bool {
        if !fileURLs.isEmpty || !images.isEmpty { return true }
        if case .attachment = text { return true }
        return false
    }

    var inlineText: String? {
        if case .inline(let text) = text { text } else { nil }
    }
}
