import UIKit

extension AttributedString {
    mutating func setSyntaxColor(_ kind: SyntaxTokenKind, in range: Range<AttributedString.Index>) {
        self[range].foregroundColor = kind.color
    }
}

private extension SyntaxTokenKind {
    var color: UIColor {
        switch self {
        case .string: .systemGreen
        case .comment: .systemGray
        case .keyword: .systemPink
        case .number: .systemOrange
        }
    }
}
