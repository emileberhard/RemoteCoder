import Foundation

struct ReviewNote: Equatable, Sendable {
    struct Anchor: Hashable, Sendable {
        let source: ChangeSource
        let path: String
        let line: Int
        let side: DiffLine.Kind
        let excerpt: String
    }

    let anchor: Anchor
    let text: String

    static let quotedCharacters = 200

    static func prompt(_ notes: [ReviewNote], scope: (ChangeSource) -> String) -> String? {
        var sections: [String] = []
        var source: ChangeSource?
        for note in notes {
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if note.anchor.source != source {
                source = note.anchor.source
                sections.append("Review comments on \(scope(note.anchor.source)):")
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
