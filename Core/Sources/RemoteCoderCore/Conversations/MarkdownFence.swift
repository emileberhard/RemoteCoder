import Foundation

/// Fenced blocks must close with the same character, at least the opening
/// length, and no trailing content. This also keeps literal fences inside code.
struct MarkdownFence: Sendable {
    let character: Character
    let length: Int
    let indentation: Int
    let language: String?

    init?(_ line: Substring) {
        indentation = line.prefix { $0 == " " }.count
        guard indentation <= 3 else { return nil }
        let content = line.dropFirst(indentation)
        guard let first = content.first, first == "`" || first == "~" else { return nil }
        character = first
        length = content.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let info = content.dropFirst(length).trimmingCharacters(in: .whitespaces)
        guard first != "`" || !info.contains("`") else { return nil }
        language = info.isEmpty ? nil : info
    }

    func closes(_ line: Substring) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let content = line.dropFirst(indent)
        let count = content.prefix { $0 == character }.count
        return count >= length && content.dropFirst(count).allSatisfy(\.isWhitespace)
    }
}
