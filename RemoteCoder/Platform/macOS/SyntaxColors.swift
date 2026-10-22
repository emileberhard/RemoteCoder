#if os(macOS)
import AppKit

extension AttributedString {
    mutating func setSyntaxColor(_ kind: SyntaxTokenKind, in range: Range<AttributedString.Index>) {
        self[range].foregroundColor = kind.color
    }
}

private extension SyntaxTokenKind {
    var color: NSColor {
        switch self {
        case .string: .systemGreen
        case .comment: .systemGray
        case .keyword: .systemPink
        case .number: .systemOrange
        }
    }
}
#endif
