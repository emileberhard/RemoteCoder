import Foundation

/// Balances only the unfinished inline tail. Escapes and code spans own their
/// delimiters, so literal multiplication and asterisks in code remain literal.
enum StreamingMarkdownTail {
    static func closing(_ source: String) -> String {
        let characters = Array(source)
        var delimiters: [String] = []
        var codeDelimiter: String?
        var index = 0
        var result = source
        while index < characters.count {
            let character = characters[index]
            if character == "\\", codeDelimiter == nil { index += 2; continue }
            guard character == "`" || (codeDelimiter == nil && (character == "*" || character == "~")) else {
                index += 1; continue
            }
            let start = index
            while index < characters.count, characters[index] == character { index += 1 }
            let count = index - start
            let token = String(repeating: String(character), count: count)
            if character == "`" {
                if codeDelimiter == token { codeDelimiter = nil }
                else if codeDelimiter == nil { codeDelimiter = token }
                continue
            }
            if character == "~", count != 2 { continue }
            let before = start > 0 ? characters[start - 1] : nil
            let after = index < characters.count ? characters[index] : nil
            let canClose = before.map { !$0.isWhitespace } ?? false
            let canOpen = after.map { !$0.isWhitespace } ?? true
            // Runs of three asterisks open bold+italic and close in reverse order.
            var remaining = count
            while remaining > 0 {
                if canClose, let last = delimiters.last,
                   last.first == character, last.count <= remaining {
                    delimiters.removeLast(); remaining -= last.count
                } else if canOpen {
                    let width = character == "~" ? 2 : min(2, remaining)
                    if after == nil {
                        result.removeLast(remaining)
                        remaining = 0
                    } else {
                        delimiters.append(String(repeating: String(character), count: width))
                        remaining -= width
                    }
                } else { remaining = 0 }
            }
        }
        if let codeDelimiter {
            if source.hasSuffix(codeDelimiter) { result.removeLast(codeDelimiter.count) }
            else { result += codeDelimiter }
        }
        return result + delimiters.reversed().joined()
    }
}
