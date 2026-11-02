import Foundation

enum ReviewComparison: Hashable, Sendable {
    case git(ChangeSource)
    case turn(id: String, startedAt: Date)
}

struct ReviewNote: Equatable, Sendable {
    struct Anchor: Hashable, Sendable {
        let comparison: ReviewComparison
        let root: String
        let path: String
        let line: Int
        let side: DiffLine.Kind
        let excerpt: String
    }

    let anchor: Anchor
    let text: String

    static let quotedCharacters = 200

    static func prompt(_ notes: [ReviewNote], scope: (Anchor) -> String) -> String? {
        var sections: [String] = []
        var group: (comparison: ReviewComparison, root: String)?
        for note in notes {
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if group?.comparison != note.anchor.comparison || group?.root != note.anchor.root {
                group = (note.anchor.comparison, note.anchor.root)
                sections.append("Review comments on \(scope(note.anchor)):")
            }
            sections.append("\(location(of: note.anchor))\n> \(marker(of: note.anchor)) \(quote(note.anchor.excerpt))\n\(text)")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private static func location(of anchor: Anchor) -> String {
        anchor.side == .deletion ? "\(anchor.path):\(anchor.line) (removed line)" : "\(anchor.path):\(anchor.line)"
    }

    private static func marker(of anchor: Anchor) -> String {
        switch anchor.side {
        case .addition: "+"
        case .deletion: "-"
        case .context: " "
        }
    }

    private static func quote(_ excerpt: String) -> String {
        excerpt.count > quotedCharacters ? excerpt.prefix(quotedCharacters) + "…" : excerpt
    }
}
