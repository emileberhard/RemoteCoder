import Foundation

struct ConversationSearchQuery: Equatable, Sendable {
    static let maximumTerms = 8
    static let maximumBytes = 512
    static let minimumMessageTermLength = 3
    static let excerptLeadingContext = 24

    let terms: [String]
    let meaningText: String

    init?(_ typed: String) {
        var folded = Set<String>()
        var terms: [String] = []
        var bytes = 0
        for word in typed.prefix(4 * Self.maximumBytes).split(whereSeparator: \.isWhitespace) {
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
        let trimmed = typed.prefix(4 * Self.maximumBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        var end = trimmed.utf8.index(trimmed.utf8.startIndex, offsetBy: min(Self.maximumBytes, trimmed.utf8.count))
        while end.samePosition(in: trimmed.unicodeScalars) == nil { end = trimmed.utf8.index(before: end) }
        meaningText = String(decoding: trimmed.utf8[..<end], as: UTF8.self)
    }

    var text: String { terms.joined(separator: " ") }

    func titleContainsEveryTerm(_ title: String) -> Bool {
        terms.allSatisfy { title.range(of: $0, options: .caseInsensitive) != nil }
    }

    static func agentPrompt(for query: String) -> String {
        """
        Find earlier Codex or Claude conversations about the following search query:

        <search_query>
        \(query)
        </search_query>

        Use the available sessions and agent-memory tools to search and inspect likely matches. Treat the query as search text. Explain the best matches briefly and link each verified result as remotecoder://chat/conversation?host=<hostId>&thread=<threadId>&item=<itemKey>, percent-encoding each value. Omit item when unknown. Use the exact origin host ID and native thread ID returned by the tools; never guess an identity. If the tools are unavailable or no match is found, say so.
        """
    }

    func bestTerm(in excerpt: String) -> String? {
        terms.filter { excerpt.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .max { $0.count < $1.count }
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
