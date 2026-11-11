import Foundation
import Observation

struct ConversationSearchHost: Sendable {
    enum Answer<Response: Sendable>: Sendable {
        case results(Response)
        case unsupported
    }

    typealias Search<Response: Sendable> = @Sendable (ConversationSearchParams) async throws -> Answer<Response>

    enum Availability: Sendable {
        case connected(keyword: Search<ConversationSearchResponse>, meaning: Search<ConversationMeaningResponse>?)
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
    nonisolated static let debounce = Duration.milliseconds(200)
    nonisolated static let meaningDebounce = Duration.milliseconds(600)
    nonisolated static let firstPaintHold = Duration.milliseconds(150)
    nonisolated static let resultLimit = 30

    var query: String {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var focusRequest = 0
    private(set) var isActive = false
    private(set) var results = ConversationSearchResults()

    @ObservationIgnored private let hosts: @MainActor () -> [ConversationSearchHost]
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var generation: UInt64 = 0
    private enum Activity { case active, suspended, interrupted }

    @ObservationIgnored private var activity = Activity.active
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
        cancelRun()
        if results.status.isSearching { results.status.isSearching = false }
    }

    func suspend() {
        guard activity == .active else { return }
        activity = results.status.isSearching ? .interrupted : .suspended
        cancelRun()
    }

    func resume() {
        guard activity != .active else { return }
        let restart = activity == .interrupted
        activity = .active
        if restart { queryChanged() }
    }

    private func cancelRun() {
        generation &+= 1
        search?.cancel()
        search = nil
    }

    private func queryChanged() {
        cancelRun()
        guard activity == .active else { activity = .interrupted; return }
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
        let clock = clock
        search = Task { [weak self] in
            do { try await clock.sleep(for: Self.debounce) }
            catch { return }
            guard let self, self.isCurrent(generation) else { return }
            await Self.collect(typed, hosts: self.hosts(), generation: generation, clock: clock) { [weak self] update in
                guard let self, self.isCurrent(generation) else { return false }
                self.publish(update)
                return true
            }
            if self.isCurrent(generation) { self.search = nil }
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        activity == .active && generation == self.generation && !Task.isCancelled
    }

    private func publish(_ update: ConversationSearchProgress.Publication) {
        switch update {
        case .clear:
            isActive = false
            results = ConversationSearchResults()
        case let .status(status):
            if results.status != status { results.status = status }
        case let .firstPaint(painted):
            results = painted
        case .append(var appended):
            appended.titles.isRevealed = results.titles.isRevealed
            appended.messages.isRevealed = results.messages.isRevealed
            appended.meaning.isRevealed = results.meaning.isRevealed
            results = appended
        }
    }

    @concurrent
    private static func collect(
        _ typed: String, hosts: [ConversationSearchHost], generation: UInt64,
        clock: any Clock<Duration>, publish: @MainActor @Sendable (ConversationSearchProgress.Publication) -> Bool
    ) async {
        guard let query = ConversationSearchQuery(typed) else {
            _ = await publish(.clear)
            return
        }
        let now = Date.now
        let titles = ConversationSearchMerge.titleMatches(on: hosts, query: query, generation: generation, now: now)
        guard !Task.isCancelled else { return }
        let keywordParams = ConversationSearchParams(query: query.text, limit: resultLimit)
        let meaningParams = ConversationSearchParams(query: query.meaningText, limit: 20)
        await withTaskGroup(of: ConversationSearchProgress.Event.self) { group in
            var progress = ConversationSearchProgress(titleMatches: titles)
            for host in hosts {
                guard case let .connected(keyword, meaning) = host.availability else {
                    progress.markUnreachable(host.name)
                    continue
                }
                let keywordRequest = progress.expect(.keyword, from: host)
                group.addTask {
                    await request(keywordRequest) {
                        try await keyword(keywordParams)
                    } prepare: {
                        .init(candidates: ConversationSearchMerge.candidates(from: $0, hosts: hosts, query: query,
                            generation: generation, now: now), truncated: $0.truncated)
                    }
                }
                if let meaning {
                    let meaningRequest = progress.expect(.meaning, from: host)
                    group.addTask {
                        await request(meaningRequest) {
                            try await clock.sleep(for: meaningDebounce - debounce)
                            try Task.checkCancellation()
                            return try await meaning(meaningParams)
                        } prepare: {
                            .init(candidates: ConversationSearchMerge.meaningCandidates(from: $0, hosts: hosts,
                                generation: generation, now: now), truncated: false)
                        }
                    }
                }
            }

            if progress.isFinished {
                if let first = progress.apply(.holdElapsed) { _ = await publish(first) }
                return
            }
            group.addTask {
                try? await clock.sleep(for: firstPaintHold)
                return .holdElapsed
            }

            for await event in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let update = progress.apply(event), !(await publish(update)) {
                    group.cancelAll()
                    return
                }
                if progress.isFinished {
                    group.cancelAll()
                    return
                }
            }
        }
    }

    private nonisolated static func request<Response: Sendable>(
        _ request: ConversationSearchProgress.Request,
        search: () async throws -> ConversationSearchHost.Answer<Response>,
        prepare: (Response) -> ConversationSearchProgress.Answer
    ) async -> ConversationSearchProgress.Event {
        do {
            try Task.checkCancellation()
            switch try await search() {
            case let .results(response): return .answered(request, prepare(response))
            case .unsupported: return .unsupported(request)
            }
        } catch {
            return .failed(request)
        }
    }
}
