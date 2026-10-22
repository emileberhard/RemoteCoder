import Foundation

final class MessageAttachment: Identifiable, Sendable, Codable, Equatable {
    enum Content: Sendable, Codable {
        case text(String)
        case imageData(CodexImageAttachment)
        case canonicalImage(Int)
        case unavailableImage
        case image(CodexAppServerV2.ImageReference)
        case localImage(path: String)
        case file(UploadedFile)
        case fileReference(path: String)
    }

    let id: UUID
    let content: Content
    private let revision: UUID
    let preview: String
    let detail: String

    private enum CodingKeys: String, CodingKey { case id, content }

    convenience init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), content: values.decode(Content.self, forKey: .content))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(content, forKey: .content)
    }

    init(id: UUID, content: Content) {
        self.id = id
        self.content = content
        switch content {
        case .text(let text):
            revision = ChatMessage.deterministicID(for: text)
            preview = UserMessageText.firstLine(text)
            let lines = text.isEmpty ? 0 : text.reduce(into: 1) { count, character in
                if character.isNewline { count += 1 }
            }
            detail = "\(lines) \(lines == 1 ? "line" : "lines")"
        case .imageData(let image):
            revision = image.id
            preview = "Image"
            detail = image.format.displayName
        case .canonicalImage(let index):
            revision = ChatMessage.deterministicID(for: "\(id)|canonical-image:\(index)")
            preview = "Image"
            detail = ""
        case .unavailableImage:
            revision = ChatMessage.deterministicID(for: "unavailable-image")
            preview = "Image unavailable"
            detail = ""
        case .image(let reference):
            switch reference {
            case .inline(let url): revision = ChatMessage.deterministicID(for: url)
            case .file(let id): revision = ChatMessage.deterministicID(for: id)
            }
            preview = "Image"
            detail = ""
        case .localImage(let path):
            revision = ChatMessage.deterministicID(for: path)
            preview = "Image"
            detail = ""
        case .file(let file):
            revision = ChatMessage.deterministicID(for: "\(file.path)|\(file.sha256)|\(file.bytes)")
            preview = file.name
            detail = ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)
        case .fileReference(let path):
            revision = ChatMessage.deterministicID(for: path)
            preview = URL(fileURLWithPath: path).lastPathComponent
            detail = ""
        }
    }

    static func == (lhs: MessageAttachment, rhs: MessageAttachment) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision
    }
}

enum PastedTextPromptBlock {
    struct Entry: Codable, Sendable, Equatable {
        let id: UUID
        let text: String
    }

    private static let start = "<remotecoder_pasted_text_v1>\n"
    private static let end = "\n</remotecoder_pasted_text_v1>"

    static func parse(_ text: String) -> (body: String, entries: [Entry])? {
        guard text.hasSuffix(end), let range = text.range(of: start, options: .backwards),
              range.lowerBound == text.startIndex || text[..<range.lowerBound].hasSuffix("\n\n") else { return nil }
        let jsonEnd = text.index(text.endIndex, offsetBy: -end.count)
        guard range.upperBound <= jsonEnd else { return nil }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: Data(text[range.upperBound..<jsonEnd].utf8)),
              !entries.isEmpty, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let body = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, entries)
    }
}

struct UserMessageText: Sendable {
    let body: String
    let pasted: [PastedTextPromptBlock.Entry]
    let filePaths: [String]
    let inline: ComposerDocumentContent?

    init(_ text: String) {
        let files = AttachedFilesPromptBlock.parse(text)
        let remaining = files?.body ?? text
        let decoded = InlinePastedText.parse(remaining)
        inline = decoded.flatMap { $0.pasted.isEmpty ? nil : $0 }
        let paste = decoded == nil ? PastedTextPromptBlock.parse(remaining) : nil
        body = decoded?.runs.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined() ?? paste?.body ?? remaining
        pasted = decoded?.pasted ?? paste?.entries ?? []
        filePaths = files?.paths ?? []
    }

    var preview: String {
        if let inline { return Self.firstLine(inline.summary) }
        guard !pasted.isEmpty || !filePaths.isEmpty else { return body }
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Self.firstLine(body) }
        if let first = pasted.first { return Self.firstLine(first.text) }
        if let path = filePaths.first { return URL(fileURLWithPath: path).lastPathComponent }
        return body
    }

    static func firstLine(_ text: String) -> String {
        let first = text.drop(while: \.isWhitespace).prefix(121).prefix(while: { !$0.isNewline })
        return String(first.prefix(120)) + (first.count > 120 ? "…" : "")
    }
}
