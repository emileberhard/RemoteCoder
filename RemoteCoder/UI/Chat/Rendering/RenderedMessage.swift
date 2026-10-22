import Foundation

struct RenderedMessage: Sendable {
    let sourceText: String
    let sourceBytes: Int
    let isStreaming: Bool
    let extendsStream: Bool
    let body: String
    let document: MarkdownDocument
    let inline: RenderedInlineMessage?
    let revision: Int

    var blocks: [RenderedMarkdownBlock] { document.blocks }
    var containsHTMLVisual: Bool { document.containsHTMLVisual }

    static func render(text: String, inline: InlineMessageContent?, isStreaming: Bool, previous: RenderedMessage?,
                       highlighting: inout SyntaxHighlightCache) -> RenderedMessage {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = inline == nil ? MarkdownRendering.parse(body, previous: previous?.document,
            isStreaming: isStreaming, highlighting: &highlighting) : .empty
        // A terminal update may contain the last suffix, so it still animates;
        // a first render or loaded history does not continue a stream.
        return RenderedMessage(
            sourceText: text, sourceBytes: (inline?.plainText ?? text).utf8.count, isStreaming: isStreaming,
            extendsStream: previous.map { isStreaming || $0.isStreaming } ?? false,
            body: body, document: document, inline: inline.map(RenderedInlineMessage.init),
            revision: (previous?.revision ?? 0) + 1
        )
    }
}

extension RenderedMessage {
    var plainText: String {
        inline?.plainText ?? blocks.map(\.content.plainText).joined(separator: "\n\n")
    }
}

extension ChatMessage {
    func markdownSource(rendered: RenderedMessage?) -> String {
        inlineContent?.plainText ?? (isStreaming ? rendered?.sourceText : nil) ?? text
    }
}

private extension RenderedMarkdownBlock.Content {
    var plainText: String {
        switch self {
        case .heading(_, let content), .paragraph(let content), .quote(let content):
            String(content.characters)
        case .bulletList(let items):
            items.map { String(repeating: "  ", count: $0.level) + "• " + String($0.content.characters) }
                .joined(separator: "\n")
        case .htmlVisual(_, let title):
            title
        case .images(let images):
            images.map(\.alt).joined(separator: "\n")
        case .codeBlock(_, let code, _):
            code
        case .mermaid(let source, _):
            source
        case .table(let headers, _, let rows, _):
            ([headers] + rows).map { $0.map { String($0.characters) }.joined(separator: "\t") }
                .joined(separator: "\n")
        }
    }
}
