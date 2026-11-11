import Foundation

struct ConversationSearchRow: Identifiable, Sendable {
    enum Headline: Sendable {
        case title(String)
        case excerpt(AttributedString)
        case untitled
    }

    let address: ConversationAddress
    let agentThreadID: String?
    let section: ConversationSearchSection.Kind
    let itemKey: String?
    let findTerm: String?
    let sessionKey: String?
    let generation: UInt64
    let headline: Headline
    let excerpt: AttributedString?
    let dateLabel: String?
    let provider: AgentProvider
    let folder: String?
    let hostName: String?
    let additionalHitCount: Int

    var id: String { address.id }
    var additionalHitLabel: String? {
        additionalHitCount > 0 ? "\(min(5, additionalHitCount))+ more" : nil
    }
    var openingAddress: ConversationAddress {
        ConversationAddress(hostID: address.hostID, threadID: agentThreadID ?? address.threadID)
    }
}

extension ConversationSearchRow: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.generation == rhs.generation }
}

struct ConversationSearchSection: Equatable, Sendable {
    enum Kind: String, Sendable {
        case titles
        case messages
        case meaning

        var visibleRowLimit: Int {
            switch self {
            case .titles: 4
            case .messages, .meaning: 10
            }
        }

        var retainedRowLimit: Int {
            switch self {
            case .titles: 50
            case .messages, .meaning: 100
            }
        }
    }

    let kind: Kind
    private(set) var rows: [ConversationSearchRow] = []
    var isRevealed = false

    var visibleRows: ArraySlice<ConversationSearchRow> { isRevealed ? rows[...] : rows.prefix(kind.visibleRowLimit) }
    var hiddenRowCount: Int { rows.count - visibleRows.count }

    mutating func append(_ row: ConversationSearchRow) {
        guard rows.count < kind.retainedRowLimit else { return }
        rows.append(row)
    }
}

struct ConversationSearchStatus: Equatable, Sendable {
    var isSearching = false
    var unansweredHosts: [String] = []
    var unsupportedHosts: [String] = []
    var partialHosts: [String] = []
    var failedMeaningHosts: [String] = []

    var isComplete: Bool {
        !isSearching && unansweredHosts.isEmpty && unsupportedHosts.isEmpty && partialHosts.isEmpty && failedMeaningHosts.isEmpty
    }

    var summary: String? {
        var parts: [String] = []
        if isSearching { parts.append("Searching…") }
        if !partialHosts.isEmpty { parts.append("Search incomplete on \(partialHosts.formatted(.list(type: .and)))") }
        if !failedMeaningHosts.isEmpty { parts.append("By meaning failed on \(failedMeaningHosts.formatted(.list(type: .and)))") }
        if !unansweredHosts.isEmpty { parts.append("No answer from \(unansweredHosts.formatted(.list(type: .and)))") }
        if !unsupportedHosts.isEmpty { parts.append("\(unsupportedHosts.formatted(.list(type: .and))) can't search messages yet") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ConversationSearchResults: Equatable, Sendable {
    var titles = ConversationSearchSection(kind: .titles)
    var messages = ConversationSearchSection(kind: .messages)
    var meaning = ConversationSearchSection(kind: .meaning)
    var status = ConversationSearchStatus()
    var isPainted = false

    var isEmpty: Bool { titles.rows.isEmpty && messages.rows.isEmpty && meaning.rows.isEmpty }

    func section(_ kind: ConversationSearchSection.Kind) -> ConversationSearchSection {
        switch kind {
        case .titles: titles
        case .messages: messages
        case .meaning: meaning
        }
    }
}

struct ConversationSearchCandidate: Sendable {
    let row: ConversationSearchRow
    let titleMatch: Bool
    let recency: Date?
}

enum ConversationSearchMerge {
    static func titleMatches(on hosts: [ConversationSearchHost], query: ConversationSearchQuery,
                             generation: UInt64, now: Date) -> [ConversationSearchCandidate] {
        let showsHostLabels = ConversationSidebarProjection.showsHostLabels(targetCount: hosts.count)
        var matches: [ConversationSearchCandidate] = []
        for host in hosts {
            for header in host.headers where !header.isDelegatedAgent && host.marks.purpose(of: header.id) != .probe {
                let title = ConversationSidebarProjection.title(for: header, pinnedName: host.marks.pinName(for: header.id))
                guard query.titleContainsEveryTerm(title) else { continue }
                let recency = Date(timeIntervalSince1970: TimeInterval(header.latestActivityAt))
                matches.append(ConversationSearchCandidate(
                    row: ConversationSearchRow(
                        address: ConversationAddress(hostID: host.id, threadID: header.id), agentThreadID: nil,
                        section: .titles, itemKey: nil, findTerm: nil, sessionKey: nil,
                        generation: generation, headline: .title(title), excerpt: nil,
                        dateLabel: dateLabel(recency, now: now), provider: AgentProvider.provider(forThreadID: header.id),
                        folder: folder(of: header.cwd), hostName: showsHostLabels ? host.name : nil, additionalHitCount: 0),
                    titleMatch: true, recency: recency))
            }
        }
        return Array(newestFirst(matches).prefix(ConversationSearchSection.Kind.titles.retainedRowLimit))
    }

    static func candidates(from response: ConversationSearchResponse, hosts: [ConversationSearchHost],
                           query: ConversationSearchQuery, generation: UInt64, now: Date) -> [ConversationSearchCandidate] {
        let showsHostLabels = ConversationSidebarProjection.showsHostLabels(targetCount: hosts.count)
        var localTitles: [UUID: [String: String]] = [:]
        return response.conversations.compactMap { conversation in
            guard let host = host(conversation.hostId, among: hosts),
                  host.marks.purpose(of: conversation.threadId) != .probe else { return nil }
            let excerpt = conversation.hits.first.map { query.emphasizedExcerpt($0.excerpt) }
            let knownTitle = conversation.title ?? {
                if localTitles[host.id] == nil {
                    localTitles[host.id] = Dictionary(host.headers.map { header in
                        (header.id, ConversationSidebarProjection.title(for: header, pinnedName: host.marks.pinName(for: header.id)))
                    }) { first, _ in first }
                }
                return localTitles[host.id]?[conversation.threadId]
            }()
            let headline: ConversationSearchRow.Headline = if let knownTitle { .title(knownTitle) }
                else if let excerpt { .excerpt(excerpt) } else { .untitled }
            let shownHits = excerpt == nil ? 0 : 1
            return ConversationSearchCandidate(
                row: ConversationSearchRow(
                    address: ConversationAddress(hostID: host.id, threadID: conversation.threadId),
                    agentThreadID: conversation.titleMatch ? nil : conversation.hits.first?.agentThreadId,
                    section: conversation.titleMatch ? .titles : .messages,
                    itemKey: conversation.titleMatch ? nil : conversation.hits.first?.itemKey,
                    findTerm: conversation.hits.first.flatMap { query.bestTerm(in: $0.excerpt) },
                    sessionKey: conversation.sessionKey, generation: generation, headline: headline,
                    excerpt: knownTitle == nil ? nil : excerpt,
                    dateLabel: conversation.lastAt.map { dateLabel($0, now: now) }, provider: conversation.provider,
                    folder: conversation.cwd.flatMap(folder(of:)), hostName: showsHostLabels ? host.name : nil,
                    additionalHitCount: max(0, conversation.hitCount - shownHits)),
                titleMatch: conversation.titleMatch, recency: conversation.lastAt)
        }
    }

    static func meaningCandidates(from response: ConversationMeaningResponse, hosts: [ConversationSearchHost],
                                  generation: UInt64, now: Date) -> [ConversationSearchCandidate] {
        let showsHostLabels = ConversationSidebarProjection.showsHostLabels(targetCount: hosts.count)
        return response.conversations.compactMap { conversation in
            guard let host = host(conversation.hostId, among: hosts),
                  host.marks.purpose(of: conversation.threadId) != .probe else { return nil }
            return ConversationSearchCandidate(row: ConversationSearchRow(
                address: ConversationAddress(hostID: host.id, threadID: conversation.threadId), agentThreadID: nil, section: .meaning,
                itemKey: nil, findTerm: nil, sessionKey: conversation.sessionKey, generation: generation,
                headline: conversation.title.map(ConversationSearchRow.Headline.title) ?? .untitled,
                excerpt: AttributedString(conversation.excerpt),
                dateLabel: conversation.lastAt.map { dateLabel($0, now: now) }, provider: conversation.provider,
                folder: conversation.cwd.flatMap(folder(of:)), hostName: showsHostLabels ? host.name : nil,
                additionalHitCount: 0), titleMatch: false, recency: conversation.lastAt)
        }
    }

    private static func host(_ id: UUID, among hosts: [ConversationSearchHost]) -> ConversationSearchHost? {
        let matches = hosts.filter { $0.id == id || $0.gatewayID == id }
        return matches.count == 1 ? matches.first : nil
    }

    static func firstPaint(of results: ConversationSearchResults, titleMatches: [ConversationSearchCandidate],
                           answer: [ConversationSearchCandidate]) -> ConversationSearchResults {
        var painted = ConversationSearchResults(status: results.status, isPainted: true)
        var listed = Set<ConversationAddress>()
        var sessionKeys = Set<String>()
        let answered = answer.filter(\.titleMatch)
        let answeredAddresses = Set(answered.map(\.row.address))
        let titles = newestFirst(answered + titleMatches.filter { !answeredAddresses.contains($0.row.address) })
        for candidate in titles where admit(candidate.row, listed: &listed, sessionKeys: &sessionKeys) {
            painted.titles.append(candidate.row)
        }
        for candidate in answer where candidate.row.section == .messages && admit(candidate.row, listed: &listed, sessionKeys: &sessionKeys) {
            painted.messages.append(candidate.row)
        }
        for candidate in answer where candidate.row.section == .meaning && admit(candidate.row, listed: &listed, sessionKeys: &sessionKeys) {
            painted.meaning.append(candidate.row)
        }
        return painted
    }

    static func appending(_ answer: [ConversationSearchCandidate],
                          to results: ConversationSearchResults) -> ConversationSearchResults {
        var appended = results
        var listed = Set((results.titles.rows + results.messages.rows + results.meaning.rows).map(\.address))
        var sessionKeys = Set((results.titles.rows + results.messages.rows + results.meaning.rows).compactMap(\.sessionKey))
        for candidate in answer where admit(candidate.row, listed: &listed, sessionKeys: &sessionKeys) {
            switch candidate.row.section {
            case .titles: appended.titles.append(candidate.row)
            case .messages: appended.messages.append(candidate.row)
            case .meaning: appended.meaning.append(candidate.row)
            }
        }
        return appended
    }

    private static func admit(_ row: ConversationSearchRow, listed: inout Set<ConversationAddress>,
                              sessionKeys: inout Set<String>) -> Bool {
        guard !listed.contains(row.address), !(row.sessionKey.map(sessionKeys.contains) ?? false) else { return false }
        listed.insert(row.address)
        if let sessionKey = row.sessionKey { sessionKeys.insert(sessionKey) }
        return true
    }

    private static func newestFirst(_ candidates: [ConversationSearchCandidate]) -> [ConversationSearchCandidate] {
        candidates.enumerated().sorted { lhs, rhs in
            switch (lhs.element.recency, rhs.element.recency) {
            case let (left?, right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func dateLabel(_ date: Date, now: Date) -> String {
        ConversationSidebarDate.label(for: date, now: now, calendar: .current, locale: .current)
    }

    private static func folder(of path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
