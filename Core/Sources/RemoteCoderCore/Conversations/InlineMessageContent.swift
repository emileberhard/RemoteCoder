import Foundation

final class InlineMessageContent: Sendable, Codable, Equatable {
    let document: ComposerDocumentContent
    let plainText: String
    let contextPreview: String
    let titles: [UUID: String]
    private let revision: UUID

    init(_ document: ComposerDocumentContent) {
        self.document = document
        plainText = document.expandedText
        contextPreview = String(document.summary.prefix(500))
        titles = Dictionary(document.pasted.map { ($0.id, Self.title(for: $0.text)) }, uniquingKeysWith: { first, _ in first })
        revision = ChatMessage.deterministicID(for: document.prompt)
    }

    private enum CodingKeys: String, CodingKey { case document }

    convenience init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try values.decode(ComposerDocumentContent.self, forKey: .document))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(document, forKey: .document)
    }

    static func == (lhs: InlineMessageContent, rhs: InlineMessageContent) -> Bool { lhs.revision == rhs.revision }

    static func title(for text: String) -> String {
        let prefix = String(text.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? "Pasted text" : String(prefix.prefix(while: { !$0.isNewline }))
    }
}
