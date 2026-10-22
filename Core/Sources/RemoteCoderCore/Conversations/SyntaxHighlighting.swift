import Foundation

enum SyntaxHighlighting {
    private static let literals = try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|//[^\r\n\u000B\u000C\u0085\u2028\u2029]*"#)
    private static let numbers = try? NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
    private static let swiftKeywords = keywords([
        "import", "class", "struct", "enum", "protocol", "extension",
        "func", "var", "let", "if", "else", "guard", "switch", "case",
        "for", "while", "return", "throw", "try", "catch", "async", "await",
        "actor", "nonisolated", "isolated", "@MainActor", "@Observable",
        "private", "public", "internal", "fileprivate", "static", "final",
        "override", "mutating", "inout", "self", "Self", "nil", "true", "false",
    ])
    private static let pythonKeywords = keywords([
        "def", "class", "import", "from", "if", "else", "elif",
        "for", "while", "return", "try", "except", "finally", "with",
        "as", "async", "await", "lambda", "pass", "break", "continue",
        "True", "False", "None", "self", "and", "or", "not", "in", "is",
    ])
    private static let javaScriptKeywords = keywords([
        "function", "const", "let", "var", "if", "else", "for", "while",
        "return", "class", "extends", "import", "export", "from", "async",
        "await", "try", "catch", "finally", "new", "this", "super",
        "true", "false", "null", "undefined",
    ])
    private static let rustKeywords = keywords([
        "fn", "let", "mut", "if", "else", "match", "loop", "while",
        "for", "return", "struct", "enum", "impl", "trait", "pub", "use",
        "mod", "async", "await", "self", "Self", "true", "false",
    ])

    private static func keywords(_ words: [String]) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "\\b(?:\(words.joined(separator: "|")))\\b")
    }

    private static func keywords(for language: String?) -> NSRegularExpression? {
        switch language?.lowercased() {
        case "swift": swiftKeywords
        case "python": pythonKeywords
        case "javascript", "js", "typescript", "ts": javaScriptKeywords
        case "rust": rustKeywords
        default: nil
        }
    }

    /// A platform-neutral read of what `highlight` colors: no UIColor, no
    /// AttributedString, just the token kind and its range in `code`.
    static func tokens(in code: String, language: String?) -> [SyntaxToken] {
        var coloredRanges: [Range<String.Index>] = []
        var tokens: [SyntaxToken] = []
        let nsRange = NSRange(code.startIndex..<code.endIndex, in: code)
        func matches(of regex: NSRegularExpression?) -> [Range<String.Index>] {
            regex?.matches(in: code, range: nsRange).compactMap { Range($0.range, in: code) } ?? []
        }

        for range in matches(of: literals) {
            let kind: SyntaxTokenKind = code.unicodeScalars[range.lowerBound] == "\"" ? .string : .comment
            tokens.append(SyntaxToken(range: range, kind: kind))
            coloredRanges.append(range)
        }

        func appendTokens(matching regex: NSRegularExpression?, kind: SyntaxTokenKind) {
            var coloredIndex = 0
            for range in matches(of: regex) {
                while coloredIndex < coloredRanges.count, coloredRanges[coloredIndex].upperBound <= range.lowerBound {
                    coloredIndex += 1
                }
                guard coloredIndex == coloredRanges.count || !coloredRanges[coloredIndex].overlaps(range) else { continue }
                tokens.append(SyntaxToken(range: range, kind: kind))
            }
        }

        appendTokens(matching: keywords(for: language), kind: .keyword)
        appendTokens(matching: numbers, kind: .number)

        return tokens
    }
}

/// Meaning, not a screen color. `SyntaxHighlighting.highlight` is the only
/// place that applies a kind's platform color.
enum SyntaxTokenKind: Sendable, Equatable {
    case string, comment, keyword, number
}

struct SyntaxToken: Sendable {
    let range: Range<String.Index>
    let kind: SyntaxTokenKind
}
