import Foundation

nonisolated struct ConversationSearchProgress {
    enum Tier: Hashable, Sendable { case keyword, meaning }

    struct Request: Hashable, Sendable {
        let host: UUID
        let tier: Tier
    }

    enum Event: Sendable {
        case holdElapsed
        case answered(Request, [ConversationSearchCandidate])
        case unsupported(Request)
        case failed(Request)
    }

    enum Publication: Sendable {
        case clear
        case status(ConversationSearchStatus)
        case firstPaint(ConversationSearchResults)
        case append(ConversationSearchResults)
    }

    private let titleMatches: [ConversationSearchCandidate]
    private var pending: [Request: String] = [:]
    private var results = ConversationSearchResults()
    private var heldMeaning: [ConversationSearchCandidate] = []

    init(titleMatches: [ConversationSearchCandidate]) {
        self.titleMatches = titleMatches
    }

    var isFinished: Bool { pending.isEmpty }

    mutating func expect(_ tier: Tier, from host: ConversationSearchHost) -> Request {
        let request = Request(host: host.id, tier: tier)
        pending[request] = host.name
        results.status.isSearching = true
        return request
    }

    mutating func markUnreachable(_ name: String) {
        results.status.unansweredHosts.append(name)
    }

    mutating func apply(_ event: Event) -> Publication? {
        let previous = results
        var answer: [ConversationSearchCandidate]?
        switch event {
        case .holdElapsed:
            if !results.isPainted { answer = [] }
        case let .answered(request, candidates):
            pending[request] = nil
            if request.tier == .meaning, !results.isPainted { heldMeaning += candidates }
            else { answer = candidates }
        case let .unsupported(request):
            if let name = pending.removeValue(forKey: request), request.tier == .keyword,
               !results.status.unsupportedHosts.contains(name) { results.status.unsupportedHosts.append(name) }
        case let .failed(request):
            if let name = pending.removeValue(forKey: request), !results.status.unansweredHosts.contains(name) {
                results.status.unansweredHosts.append(name)
            }
        }
        results.status.isSearching = !isFinished

        if results.isPainted {
            if let answer { results = ConversationSearchMerge.appending(answer, to: results) }
            return results == previous ? nil : .append(results)
        }
        if let answer = answer ?? (isFinished ? [] : nil) {
            results = ConversationSearchMerge.firstPaint(of: results, titleMatches: titleMatches, answer: answer + heldMeaning)
            heldMeaning.removeAll()
            return .firstPaint(results)
        }
        return .status(results.status)
    }
}
