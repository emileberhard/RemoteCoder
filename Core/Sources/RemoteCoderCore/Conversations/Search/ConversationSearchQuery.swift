import Foundation

struct ConversationSearchQuery: Equatable, Sendable {
    static let maximumTerms = 8
    static let maximumBytes = 512
    static let minimumMessageTermLength = 3
    static let excerptLeadingContext = 24

    let terms: [String]

    init?(_ typed: String) {
        var folded = Set<String>()
        var terms: [String] = []
        var bytes = 0
        for word in typed.split(whereSeparator: \.isWhitespace) {
            let term = String(word)
            guard !folded.contains(term.lowercased()) else { continue }
            let added = term.utf8.count + (terms.isEmpty ? 0 : 1)
            guard terms.count < Self.maximumTerms, bytes + added <= Self.maximumBytes else { break }
            folded.insert(term.lowercased())
            terms.append(term)
            bytes += added
        }
        guard !terms.isEmpty else { return nil }
        self.terms = terms
    }

    var text: String { terms.joined(separator: " ") }

    func titleContainsEveryTerm(_ title: String) -> Bool {
        terms.allSatisfy { title.range(of: $0, options: .caseInsensitive) != nil }
    }

    func emphasizedExcerpt(_ excerpt: String) -> AttributedString {
        let flattened = excerpt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let messageTerms = terms.filter { $0.unicodeScalars.count >= Self.minimumMessageTermLength }
        let focused = Self.focus(flattened, on: messageTerms)
        var attributed = AttributedString(focused)
        for term in messageTerms {
            var searchStart = focused.startIndex
            while let match = focused.range(of: term, options: .caseInsensitive, range: searchStart..<focused.endIndex) {
                if let lower = AttributedString.Index(match.lowerBound, within: attributed),
                   let upper = AttributedString.Index(match.upperBound, within: attributed) {
                    attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                }
                searchStart = match.upperBound
            }
        }
        return attributed
    }

    private static func focus(_ text: String, on terms: [String]) -> String {
        let firstMatch = terms.compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }.min()
        guard let firstMatch,
              text.distance(from: text.startIndex, to: firstMatch) > excerptLeadingContext else { return text }
        var start = text.index(firstMatch, offsetBy: -excerptLeadingContext)
        if let space = text[start..<firstMatch].firstIndex(of: " ") { start = text.index(after: space) }
        return "…" + text[start...]
    }
}
