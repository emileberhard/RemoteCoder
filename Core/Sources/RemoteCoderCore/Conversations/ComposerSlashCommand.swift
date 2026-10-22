import Foundation

enum ComposerSlashCommand: String, CaseIterable, Identifiable, Sendable {
    case compact

    var id: String { rawValue }
    var invocation: String { "/" + rawValue }
    var title: String { "Compact conversation" }
    var summary: String { "Summarize context to make room for what’s next." }
    var systemImage: String { "arrow.down.right.and.arrow.up.left" }

    enum Input: Equatable, Sendable {
        case message
        case command(ComposerSlashCommand)
        case incomplete
        case unsupported(String)
        case unexpectedArguments(ComposerSlashCommand)
    }

    static func parse(_ input: String) -> Input {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return .message }
        let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let name = parts.first else { return .message }
        if let command = allCases.first(where: { $0.invocation == name.lowercased() }) {
            return parts.count == 1 ? .command(command) : .unexpectedArguments(command)
        }
        if parts.count == 1, allCases.contains(where: { $0.invocation.hasPrefix(name.lowercased()) }) {
            return .incomplete
        }
        // File paths and longer prose that starts with a slash remain ordinary messages.
        if name.dropFirst().contains("/") || parts.count > 1 { return .message }
        return .unsupported(String(name))
    }

    static func suggestions(for input: String) -> [Self] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        return allCases.filter { $0.invocation.hasPrefix(text) }
    }
}
