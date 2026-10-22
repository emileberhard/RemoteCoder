import Foundation

struct CommandPaletteCandidate<ID: Hashable & Sendable>: Sendable {
    let id: ID
    fileprivate let title: CommandPaletteSearchText
    fileprivate let detail: CommandPaletteSearchText

    init(id: ID, title: String, detail: String) {
        self.id = id
        self.title = CommandPaletteSearchText(title)
        self.detail = CommandPaletteSearchText(detail)
    }
}

enum CommandPaletteSearch {
    static func results<ID>(for query: String, in candidates: [CommandPaletteCandidate<ID>], limit: Int) -> [ID] {
        let tokens = CommandPaletteSearchText.fold(query).split(whereSeparator: \.isWhitespace).map(Array.init)
        guard !tokens.isEmpty else { return candidates.prefix(limit).map(\.id) }
        let ranked = candidates.enumerated().compactMap { index, candidate -> (score: Int, index: Int)? in
            var total = 0
            for token in tokens {
                guard let score = score(token, in: candidate) else { return nil }
                total += score
            }
            return (total, index)
        }
        return ranked
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(limit)
            .map { candidates[$0.index].id }
    }

    private static func score<ID>(_ token: [Character], in candidate: CommandPaletteCandidate<ID>) -> Int? {
        let scores = [
            candidate.title.occurrenceScore(of: token, prefix: 1000, wordStart: 800, anywhere: 600),
            candidate.title.subsequenceScore(of: token),
            candidate.detail.occurrenceScore(of: token, prefix: 400, wordStart: 400, anywhere: 250),
        ]
        return scores.compactMap(\.self).max()
    }
}

private struct CommandPaletteSearchText: Sendable {
    private static let characterLimit = 256

    let characters: [Character]
    let wordStarts: [Bool]

    init(_ text: String) {
        let folded = Array(Self.fold(text).prefix(Self.characterLimit))
        characters = folded
        wordStarts = folded.indices.map { index in
            index == 0 || !(folded[index - 1].isLetter || folded[index - 1].isNumber)
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func occurrenceScore(of token: [Character], prefix: Int, wordStart: Int, anywhere: Int) -> Int? {
        guard let head = token.first, token.count <= characters.count else { return nil }
        var best: Int?
        for start in 0...(characters.count - token.count) where characters[start] == head {
            guard characters[start..<(start + token.count)].elementsEqual(token) else { continue }
            if start == 0 { return prefix }
            best = max(best ?? anywhere, wordStarts[start] ? wordStart : anywhere)
        }
        return best
    }

    func subsequenceScore(of token: [Character]) -> Int? {
        var first: Int?
        var matched = 0
        for (index, character) in characters.enumerated() where character == token[matched] {
            if first == nil { first = index }
            matched += 1
            if matched == token.count {
                let spread = index - (first ?? index) + 1 - token.count
                return max(100, 300 - spread * 10)
            }
        }
        return nil
    }
}
