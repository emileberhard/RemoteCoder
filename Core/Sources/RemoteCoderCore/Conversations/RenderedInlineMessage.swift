import Foundation

struct RenderedInlineMessage: Sendable, Equatable {
    enum Run: Sendable {
        case text(AttributedString)
        case paste(PastedTextPromptBlock.Entry)
    }

    let source: InlineMessageContent
    let runs: [Run]
    let plainText: String
    private let version = UUID()

    init(_ source: InlineMessageContent) {
        self.source = source
        let prepared: [Run] = source.document.runs.map { run in
            switch run {
            case .text(let text): .text(MarkdownInlineRendering.parse(text))
            case .paste(let entry): .paste(entry)
            }
        }
        runs = prepared
        plainText = prepared.map { run in
            switch run {
            case .text(let text): String(text.characters)
            case .paste(let entry): entry.text
            }
        }.joined()
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version }
}
