import Foundation
import Observation

struct ConversationSearchHost: Sendable {
    enum Answer: Sendable {
        case results(ConversationSearchResponse)
        case unsupported
    }

    enum MeaningAnswer: Sendable {
        case results(ConversationMeaningResponse)
        case unsupported
    }

    enum Availability: Sendable {
        case connected(@Sendable (ConversationSearchParams) async throws -> Answer)
        case unreachable
    }

    let id: UUID
    let name: String
    let gatewayID: UUID?
    let headers: [ConversationHeader]
    let marks: ConversationMarks
    let availability: Availability
    var meaning: (@Sendable (ConversationSearchParams) async throws -> MeaningAnswer)? = nil
}

@MainActor
@Observable
final class ConversationSearchSession {
    static let debounce = Duration.milliseconds(200)
    static let firstPaintHold = Duration.milliseconds(150)
    static let resultLimit = 30

    var query: String {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var focusRequest = 0
    private(set) var isActive = false
    private(set) var results = ConversationSearchResults()

    @ObservationIgnored private let hosts: @MainActor () -> [ConversationSearchHost]
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private let logger = AppLogger(category: "ConversationSearch")

    init(clock: any Clock<Duration> = ContinuousClock(), hosts: @escaping @MainActor () -> [ConversationSearchHost]) {
        self.query = ""
        self.clock = clock
        self.hosts = hosts
    }

    #if DEBUG
    init(previewQuery: String, results: ConversationSearchResults) {
        self.query = previewQuery
        self.clock = ContinuousClock()
        self.hosts = { [] }
        self.isActive = true
        self.results = results
    }
    #endif

    func requestFocus() { focusRequest &+= 1 }

    func reveal(_ kind: ConversationSearchSection.Kind) {
        switch kind {
        case .titles: results.titles.isRevealed = true
        case .messages: results.messages.isRevealed = true
        case .meaning: results.meaning.isRevealed = true
        }
    }

    func recordOpening(_ row: ConversationSearchRow) {
        for kind in [ConversationSearchSection.Kind.titles, .messages, .meaning] {
            guard let index = results.section(kind).rows.firstIndex(of: row) else { continue }
            logger.notice("search result opened section=\(kind.rawValue) rank=\(index + 1)")
            return
        }
    }

    func cancel() {
        generation &+= 1
        search?.cancel()
        search = nil
        if results.status.isSearching { results.status.isSearching = false }
    }

    private func queryChanged() {
        generation &+= 1
        search?.cancel()
        let typed = query
        guard typed.prefix(4 * ConversationSearchQuery.maximumBytes).contains(where: { !$0.isWhitespace }) else {
            search = nil
            isActive = false
            results = ConversationSearchResults()
            return
        }
        if !isActive { isActive = true }
        results.status = ConversationSearchStatus(isSearching: true)
        let generation = generation
        search = Task { [weak self] in await self?.run(typed, generation: generation) }
    }

    private struct Request: Hashable, Sendable {
        let host: UUID
        let meaning: Bool
    }

    private enum Event: Sendable {
        case holdElapsed
        case answered(Request, [ConversationSearchCandidate])
        case unsupported(Request)
        case failed(Request)
    }

    private func run(_ typed: String, generation: UInt64) async {
        do { try await clock.sleep(for: Self.debounce) } catch { return }
        guard generation == self.generation else { return }
        let hosts = hosts()
        let now = Date.now
        let prepared = await Self.prepare(typed, on: hosts, generation: generation, now: now)
        guard generation == self.generation else { return }
        guard let (query, titleMatches) = prepared else {
            search = nil
            isActive = false
            results = ConversationSearchResults()
            return
        }
        var current = ConversationSearchResults()
        let params = ConversationSearchParams(query: query.text, limit: Self.resultLimit)
        let meaningParams = ConversationSearchParams(query: query.meaningText, limit: 20)
        let clock = clock
        await withTaskGroup(of: Event.self) { group in
            var pending: [Request: String] = [:]
            for host in hosts {
                switch host.availability {
                case let .connected(search):
                    let request = Request(host: host.id, meaning: false)
                    pending[request] = host.name
                    group.addTask {
                        do {
                            switch try await search(params) {
                            case let .results(response):
                                return .answered(request, await Self.candidates(from: response, hosts: hosts, query: query,
                                                                                generation: generation, now: now))
                            case .unsupported: return .unsupported(request)
                            }
                        } catch { return .failed(request) }
                    }
                    if let meaning = host.meaning {
                        let request = Request(host: host.id, meaning: true)
                        pending[request] = host.name
                        group.addTask {
                            do {
                                switch try await meaning(meaningParams) {
                                case let .results(response):
                                    return .answered(request, await Self.meaningCandidates(from: response, hosts: hosts,
                                                                                           generation: generation, now: now))
                                case .unsupported: return .unsupported(request)
                                }
                            } catch { return .failed(request) }
                        }
                    }
                case .unreachable: current.status.unansweredHosts.append(host.name)
                }
            }
            current.status.isSearching = !pending.isEmpty
            if pending.isEmpty {
                current = await Self.firstPaint(of: current, titleMatches: titleMatches, answer: [])
                if generation == self.generation { results = current }
                return
            }
            group.addTask {
                try? await clock.sleep(for: Self.firstPaintHold)
                return .holdElapsed
            }
            var heldMeaning: [ConversationSearchCandidate] = []
            var hasPublished = false
            for await event in group {
                guard generation == self.generation, !Task.isCancelled else { group.cancelAll(); return }
                var answer: [ConversationSearchCandidate]?
                switch event {
                case .holdElapsed:
                    if !current.isPainted { answer = [] }
                case let .answered(request, candidates):
                    pending[request] = nil
                    if request.meaning, !current.isPainted { heldMeaning += candidates }
                    else { answer = candidates }
                case let .unsupported(request):
                    if let name = pending.removeValue(forKey: request), !request.meaning,
                       !current.status.unsupportedHosts.contains(name) { current.status.unsupportedHosts.append(name) }
                case let .failed(request):
                    if let name = pending.removeValue(forKey: request), !current.status.unansweredHosts.contains(name) {
                        current.status.unansweredHosts.append(name)
                    }
                }
                if pending.isEmpty, !current.isPainted, answer == nil { answer = [] }
                current.status.isSearching = !pending.isEmpty
                if let answer {
                    let wasPainted = current.isPainted
                    current = wasPainted
                        ? await Self.appending(answer, to: current)
                        : await Self.firstPaint(of: current, titleMatches: titleMatches, answer: answer + heldMeaning)
                    guard generation == self.generation, !Task.isCancelled else { group.cancelAll(); return }
                    heldMeaning.removeAll()
                }
                if hasPublished {
                    current.titles.isRevealed = results.titles.isRevealed
                    current.messages.isRevealed = results.messages.isRevealed
                    current.meaning.isRevealed = results.meaning.isRevealed
                }
                if current.isPainted {
                    if current != results { results = current }
                    hasPublished = true
                } else if current.status != results.status {
                    results.status = current.status
                }
                if pending.isEmpty { group.cancelAll() }
            }
        }
        if generation == self.generation { search = nil }
    }

    @concurrent
    private static func meaningCandidates(from response: ConversationMeaningResponse, hosts: [ConversationSearchHost],
                                          generation: UInt64, now: Date) async -> [ConversationSearchCandidate] {
        ConversationSearchMerge.meaningCandidates(from: response, hosts: hosts, generation: generation, now: now)
    }

    @concurrent
    private static func prepare(_ typed: String, on hosts: [ConversationSearchHost], generation: UInt64,
                                now: Date) async -> (ConversationSearchQuery, [ConversationSearchCandidate])? {
        guard let query = ConversationSearchQuery(typed) else { return nil }
        return (query, ConversationSearchMerge.titleMatches(on: hosts, query: query, generation: generation, now: now))
    }

    @concurrent
    private static func candidates(from response: ConversationSearchResponse, hosts: [ConversationSearchHost],
                                   query: ConversationSearchQuery, generation: UInt64,
                                   now: Date) async -> [ConversationSearchCandidate] {
        ConversationSearchMerge.candidates(from: response, hosts: hosts, query: query, generation: generation, now: now)
    }

    @concurrent
    private static func firstPaint(of results: ConversationSearchResults, titleMatches: [ConversationSearchCandidate],
                                   answer: [ConversationSearchCandidate]) async -> ConversationSearchResults {
        ConversationSearchMerge.firstPaint(of: results, titleMatches: titleMatches, answer: answer)
    }

    @concurrent
    private static func appending(_ answer: [ConversationSearchCandidate],
                                  to results: ConversationSearchResults) async -> ConversationSearchResults {
        ConversationSearchMerge.appending(answer, to: results)
    }
}
