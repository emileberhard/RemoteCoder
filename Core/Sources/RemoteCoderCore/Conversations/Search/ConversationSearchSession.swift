import Foundation
import Observation

struct ConversationSearchHost: Sendable {
    enum Answer: Sendable {
        case results(ConversationSearchResponse)
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
}

@MainActor
@Observable
final class ConversationSearchSession {
    static let debounce = Duration.milliseconds(200)
    static let firstPaintHold = Duration.milliseconds(150)
    static let resultLimit = 30

    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var isActive = false
    private(set) var results = ConversationSearchResults()

    @ObservationIgnored private let hosts: @MainActor () -> [ConversationSearchHost]
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var normalized: ConversationSearchQuery?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private let logger = AppLogger(category: "ConversationSearch")

    init(clock: any Clock<Duration> = ContinuousClock(), hosts: @escaping @MainActor () -> [ConversationSearchHost]) {
        self.clock = clock
        self.hosts = hosts
    }

    func reveal(_ kind: ConversationSearchSection.Kind) {
        switch kind {
        case .titles: results.titles.isRevealed = true
        case .messages: results.messages.isRevealed = true
        }
    }

    func recordOpening(_ row: ConversationSearchRow) {
        for kind in [ConversationSearchSection.Kind.titles, .messages] {
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
        let next = ConversationSearchQuery(query)
        guard next != normalized else { return }
        normalized = next
        generation &+= 1
        search?.cancel()
        guard let next else {
            search = nil
            isActive = false
            results = ConversationSearchResults()
            return
        }
        if !isActive { isActive = true }
        results.status = ConversationSearchStatus(isSearching: true)
        let generation = generation
        search = Task { [weak self] in await self?.run(next, generation: generation) }
    }

    private enum Event: Sendable {
        case holdElapsed
        case answered(UUID, [ConversationSearchCandidate])
        case unsupported(UUID)
        case failed(UUID)
    }

    private func run(_ query: ConversationSearchQuery, generation: UInt64) async {
        do { try await clock.sleep(for: Self.debounce) } catch { return }
        guard generation == self.generation else { return }
        let hosts = hosts()
        let now = Date.now
        let titleMatches = await Self.titleMatches(on: hosts, query: query, generation: generation, now: now)
        guard generation == self.generation else { return }

        var pending: [UUID: String] = [:]
        var status = ConversationSearchStatus()
        var searches: [(UUID, @Sendable (ConversationSearchParams) async throws -> ConversationSearchHost.Answer)] = []
        for host in hosts {
            switch host.availability {
            case let .connected(search):
                pending[host.id] = host.name
                searches.append((host.id, search))
            case .unreachable:
                status.unansweredHosts.append(host.name)
            }
        }
        status.isSearching = !pending.isEmpty
        results.status = status
        if pending.isEmpty {
            results = await Self.firstPaint(of: results, titleMatches: titleMatches, answer: [])
            search = nil
            return
        }

        let params = ConversationSearchParams(query: query.text, limit: Self.resultLimit)
        let clock = clock
        let hold = Self.firstPaintHold
        await withTaskGroup(of: Event.self) { group in
            for (id, search) in searches {
                group.addTask {
                    do {
                        switch try await search(params) {
                        case let .results(response):
                            return .answered(id, await Self.candidates(from: response, hosts: hosts, query: query,
                                                                       generation: generation, now: now))
                        case .unsupported:
                            return .unsupported(id)
                        }
                    } catch {
                        return .failed(id)
                    }
                }
            }
            group.addTask {
                try? await clock.sleep(for: hold)
                return .holdElapsed
            }
            for await event in group {
                guard generation == self.generation, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                var answer: [ConversationSearchCandidate]?
                switch event {
                case .holdElapsed:
                    if !results.isPainted { answer = [] }
                case let .answered(id, candidates):
                    pending[id] = nil
                    answer = candidates
                case let .unsupported(id):
                    if let name = pending.removeValue(forKey: id) { status.unsupportedHosts.append(name) }
                case let .failed(id):
                    if let name = pending.removeValue(forKey: id) { status.unansweredHosts.append(name) }
                }
                if pending.isEmpty, !results.isPainted, answer == nil { answer = [] }
                status.isSearching = !pending.isEmpty
                var next = results
                next.status = status
                if let answer {
                    next = results.isPainted
                        ? await Self.appending(answer, to: next)
                        : await Self.firstPaint(of: next, titleMatches: titleMatches, answer: answer)
                    guard generation == self.generation else { return }
                }
                if next != results { results = next }
                if pending.isEmpty { group.cancelAll() }
            }
        }
        if generation == self.generation { search = nil }
    }

    @concurrent
    private static func titleMatches(on hosts: [ConversationSearchHost], query: ConversationSearchQuery,
                                     generation: UInt64, now: Date) async -> [ConversationSearchCandidate] {
        ConversationSearchMerge.titleMatches(on: hosts, query: query, generation: generation, now: now)
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
