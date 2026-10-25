import Foundation

/// One sidebar row, already resolved against its owning host's home path,
/// pins and activity state.
struct ConversationSidebarRow: Identifiable, Equatable, Sendable {
    let id: String
    let address: ConversationAddress
    let hostName: String
    /// False while only one host is configured, so the one-host drawer looks
    /// exactly like it did before.
    let showsHostLabel: Bool
    let title: String
    let preview: String
    let sidebarDate: Date
    let dateLabel: String
    let ageLabel: String
    let workingDirectory: String
    let isPinned: Bool
    let isUnread: Bool
    let isSelected: Bool
    let isLoading: Bool
    let activity: CodexGatewayDaemon.ActivityState?
    var isAutomation = false
    var questionCount: Int? = nil
    var settlement: Settlement = .unavailable
    var isProbablyDone = false
    var needsInput = false

    enum Settlement: Equatable, Sendable {
        case unavailable
        case unsettled
        case settled
    }

    var isSettled: Bool { settlement == .settled }
    var canSettle: Bool { settlement == .unsettled && activity != .working }
}

enum ConversationSectionFold: Equatable, Sendable {
    case expanded
    case folded
    case searching
}

struct ConversationSectionSummary: Equatable, Sendable {
    var fold: ConversationSectionFold
    let rowCount: Int
    let unreadCount: Int
    let liveActivity: CodexGatewayDaemon.ActivityState?
}

extension ConversationSectionSummary {
    init(_ rows: some Collection<ConversationSidebarRow>, fold: ConversationSectionFold) {
        let liveActivity: CodexGatewayDaemon.ActivityState? = if rows.contains(where: \.needsInput) {
            .waiting
        } else if rows.contains(where: { $0.activity == .working }) {
            .working
        } else if rows.contains(where: { $0.activity == .unknown }) {
            .unknown
        } else {
            nil
        }
        self.init(fold: fold, rowCount: rows.count, unreadCount: rows.count(where: \.isUnread),
                  liveActivity: liveActivity)
    }
}

struct ConversationProjectHeader: Equatable, Sendable {
    let key: String
    let title: String
    let hostName: String?
    var summary: ConversationSectionSummary
}

enum ConversationSidebarItem: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case pinnedHeader
        case chatsHeader
        case project(String)
        case more(String)
        case automationsHeader
        case moreAutomations
        case settledHeader
        case moreSettled
        case row(String)
    }

    case pinnedHeader(ConversationSectionSummary)
    case chatsHeader
    case project(ConversationProjectHeader)
    case more(projectKey: String, hiddenCount: Int)
    case automationsHeader(ConversationSectionSummary)
    case moreAutomations(hiddenCount: Int)
    case settledHeader(ConversationSectionSummary)
    case moreSettled(hiddenCount: Int)
    case row(ConversationSidebarRow)

    static func risingRowIDs(from old: [Self], to new: [Self]) -> Set<String> {
        let oldIDs = old.compactMap { item in if case let .row(row) = item { row.id } else { nil } }
        let newIDs = new.compactMap { item in if case let .row(row) = item { row.id } else { nil } }
        let shared = Set(oldIDs).intersection(newIDs)
        let oldPositions = Dictionary(uniqueKeysWithValues: oldIDs.filter { shared.contains($0) }.enumerated().map { ($0.element, $0.offset) })
        return Set(newIDs.filter { shared.contains($0) }.enumerated().compactMap { index, id in
            guard let previous = oldPositions[id], index < previous else { return nil }
            return id
        })
    }

    func keepingFold(of displayed: Self) -> Self {
        switch (self, displayed) {
        case (.pinnedHeader(var summary), .pinnedHeader(let shown)):
            summary.fold = shown.fold
            return .pinnedHeader(summary)
        case (.project(var header), .project(let shown)):
            header.summary.fold = shown.summary.fold
            return .project(header)
        case (.automationsHeader(var summary), .automationsHeader(let shown)):
            summary.fold = shown.fold
            return .automationsHeader(summary)
        case (.settledHeader(var summary), .settledHeader(let shown)):
            summary.fold = shown.fold
            return .settledHeader(summary)
        default:
            return self
        }
    }

    var id: ID {
        switch self {
        case .pinnedHeader: .pinnedHeader
        case .chatsHeader: .chatsHeader
        case let .project(header): .project(header.key)
        case let .more(key, _): .more(key)
        case .automationsHeader: .automationsHeader
        case .moreAutomations: .moreAutomations
        case .settledHeader: .settledHeader
        case .moreSettled: .moreSettled
        case let .row(row): .row(row.id)
        }
    }
}

enum ConversationSidebarHostStatus: Equatable, Sendable {
    case updating
    case failed(String)
}

/// A host's own loading/error state, so an unreachable gateway is attributable
/// instead of silently missing from the merged list.
struct ConversationSidebarHostState: Identifiable, Equatable, Sendable {
    let hostID: UUID
    let hostName: String
    let isLoading: Bool
    let status: ConversationSidebarHostStatus?
    let rowCount: Int
    var canLoadMore = false
    var hasDiscardedHeaders = false
    var unloadedPins: [String: String] = [:]
    var showsHostLabel = false

    var id: String { ExecutionTarget(hostID: hostID).id }
}

struct ConversationSidebarSnapshot: Equatable, Sendable {
    let drafts: [UnsentDraftRow]
    let hiddenDraftCount: Int
    let items: [ConversationSidebarItem]
    let hostStates: [ConversationSidebarHostState]
    var admittedLayout: ConversationDrawerLayout? = nil

    func heldInLayout(of displayed: Self) -> Self {
        let updated = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return Self(drafts: drafts, hiddenDraftCount: hiddenDraftCount, items: displayed.items.map { shown in updated[shown.id]?.keepingFold(of: shown) ?? shown },
                    hostStates: hostStates, admittedLayout: admittedLayout)
    }
}

/// Everything the projection needs from one retained chat model.
struct ConversationSidebarHostInput {
    let hostID: UUID
    let hostName: String
    let threads: [ConversationHeader]
    let marks: ConversationMarks
    let remoteHomePath: String?
    let activityByThreadID: [String: CodexGatewayDaemon.ActivityState]
    let activeThreadID: String?
    let loadingThreadID: String?
    let isLoading: Bool
    let errorMessage: String?
    var isGatewayRestarting = false
    var questionAskTimesByThreadID: [String: [Int64]] = [:]
    var waitingSinceByThreadID: [String: Int64] = [:]
    var projects: [String: ProjectIdentity] = [:]
    var settlementEdits: [String: Int] = [:]
    var canLoadMore = false
    var hasDiscardedHeaders = false
    var unloadedPins: [String: String] = [:]

    var target: ExecutionTarget { ExecutionTarget(hostID: hostID) }
}

enum ConversationSidebarProjection {
    static func showsHostLabels(targetCount: Int) -> Bool { targetCount > 1 }

    static func layout(hosts: [ConversationSidebarHostInput], at date: Date) -> ConversationDrawerLayout {
        let capturedAt = Int64(date.timeIntervalSince1970)
        var ranksByTarget: [ExecutionTarget: [String: ConversationDrawerRank]] = [:]
        for host in hosts {
            var ranks: [String: ConversationDrawerRank] = [:]
            ranks.reserveCapacity(host.threads.count)
            for thread in host.threads where !thread.isDelegatedAgent {
                ranks[thread.id] = drawerRank(of: thread, on: host, at: capturedAt)
            }
            ranksByTarget[host.target] = ranks
        }
        return ConversationDrawerLayout(capturedAt: capturedAt, ranksByTarget: ranksByTarget)
    }

    static func admittingLayout(hosts: [ConversationSidebarHostInput], layout: ConversationDrawerLayout) -> ConversationDrawerLayout {
        var arrivals: [ExecutionTarget: [String: ConversationDrawerRank]] = [:]
        for host in hosts {
            let captured = layout.ranks(on: host.target)
            for thread in host.threads where !thread.isDelegatedAgent {
                let edit = host.settlementEdits[thread.id] ?? 0
                guard captured[thread.id]?.holdsSettlement(edit: edit, mark: .init(of: thread.id, in: host.marks)) != true
                else { continue }
                arrivals[host.target, default: [:]][thread.id] = drawerRank(of: thread, on: host, at: layout.capturedAt)
            }
        }
        return arrivals.isEmpty ? layout : layout.admitting(arrivals)
    }

    static func settlement(of thread: ConversationHeader, marks: ConversationMarks,
                           activity: CodexGatewayDaemon.ActivityState?, questionAskTimes: [Int64],
                           waitingSince: Int64?, settlementEdit: Int, captured: ConversationDrawerRank?,
                           at now: Int64) -> ConversationSidebarRow.Settlement {
        guard marks.offersSettlement, !thread.isDelegatedAgent else { return .unavailable }
        let live = ConversationDrawerRank(thread, activity: activity, questionAskTimes: questionAskTimes,
                                          waitingSince: waitingSince, marks: marks, settlementEdit: settlementEdit, at: now)
        return marks.pinName(for: thread.id) == nil && held(live, captured).isSettled ? .settled : .unsettled
    }

    private static func drawerRank(of thread: ConversationHeader, on host: ConversationSidebarHostInput,
                                   at now: Int64) -> ConversationDrawerRank {
        ConversationDrawerRank(thread, activity: host.activityByThreadID[thread.id],
                               questionAskTimes: host.questionAskTimesByThreadID[thread.id] ?? [],
                               waitingSince: host.waitingSinceByThreadID[thread.id], marks: host.marks,
                               settlementEdit: host.settlementEdits[thread.id] ?? 0, at: now)
    }

    private static func held(_ live: ConversationDrawerRank, _ captured: ConversationDrawerRank?) -> ConversationDrawerRank {
        guard let captured, captured.holdsSettlement(edit: live.settlementEdit, mark: live.settlementMark) else { return live }
        return captured
    }

    /// Pinned rows by name, then automation rows, then rows that need you,
    /// running rows, unread rows and the rest, each tier by latest activity,
    /// then settled rows by latest activity, with the composite address as a
    /// stable tie-breaker. Projects mode groups the unpinned, unsettled rows by
    /// project and orders the projects by their latest activity. A row captured in `layout` keeps its
    /// rank, settlement included, while the drawer stays open until its
    /// settlement mark changes on any device, except that Unread Only lists a
    /// row that turns unread among the chats; a row the capture did not know
    /// keeps its first admitted rank.
    static func items(
        hosts: [ConversationSidebarHostInput],
        selectedHostID: UUID?,
        layout: ConversationDrawerLayout,
        arrangement: ConversationDrawerArrangement,
        condensedPaths: CondensedPathCache,
        now: Date = .now,
        dateLabels: ConversationSidebarDateCache = ConversationSidebarDateCache()
    ) -> [ConversationSidebarItem] {
        let showsHostLabel = showsHostLabels(targetCount: hosts.count)
        let terms = arrangement.query.split(whereSeparator: \.isWhitespace).map(String.init)
        let dateLabel = dateLabels.labeler(now: now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
        var slots: [Slot] = []
        slots.reserveCapacity(hosts.reduce(0) { $0 + $1.threads.count })
        for host in hosts {
            let captured = layout.ranks(on: host.target)
            for thread in host.threads where !thread.isDelegatedAgent {
                let address = ConversationAddress(hostID: host.hostID, threadID: thread.id)
                let activity = host.activityByThreadID[thread.id]
                let questionCount = host.questionAskTimesByThreadID[thread.id]?.count
                // Only the visible host's open conversation is "current";
                // a hidden host's selection is its own business.
                let isSelected = host.hostID == selectedHostID
                    && host.activeThreadID == thread.id
                let live = drawerRank(of: thread, on: host, at: layout.capturedAt)
                let rank = held(live, captured[thread.id])
                let isUnread = live.isUnread
                if host.marks.purpose(of: thread.id) == .probe, !live.isLive, !isSelected { continue }
                let pinnedName = host.marks.pinName(for: thread.id)
                let isAutomation = host.marks.purpose(of: thread.id) == .automation
                let isSettled = pinnedName == nil && rank.isSettled && !(arrangement.unreadOnly && isUnread)
                if arrangement.unreadOnly, !isSelected, isSettled || (!isUnread && !rank.isUnread) { continue }
                let sidebarDate = Date(timeIntervalSince1970: TimeInterval(thread.latestActivityAt))
                let row = ConversationSidebarRow(
                    id: address.id,
                    address: address,
                    hostName: host.hostName,
                    showsHostLabel: showsHostLabel,
                    title: title(for: thread, pinnedName: pinnedName),
                    preview: thread.preview,
                    sidebarDate: sidebarDate,
                    dateLabel: dateLabel(sidebarDate),
                    ageLabel: ConversationSidebarDate.age(of: sidebarDate, now: now),
                    workingDirectory: condensedPaths.condensedPath(thread.cwd, remoteHomePath: host.remoteHomePath),
                    isPinned: pinnedName != nil,
                    isUnread: isUnread,
                    isSelected: isSelected,
                    isLoading: host.loadingThreadID == thread.id,
                    activity: activity,
                    isAutomation: isAutomation,
                    questionCount: questionCount,
                    settlement: !host.marks.offersSettlement ? .unavailable : isSettled ? .settled : .unsettled,
                    isProbablyDone: !live.isLive && !isSettled && host.marks.isProbablyDone(thread),
                    needsInput: live.tier == .needsYou
                )
                guard matches(row, terms: terms) else { continue }
                slots.append(Slot(
                    row: row,
                    rank: rank,
                    pinnedName: pinnedName,
                    isSettled: isSettled,
                    project: arrangement.mode == .projects && pinnedName == nil && !isSettled && !isAutomation
                        ? project(of: thread, on: host, condensedPaths: condensedPaths) : nil
                ))
            }
        }
        slots.sort { $0.precedes($1) }

        var items: [ConversationSidebarItem] = []
        items.reserveCapacity(slots.count + 8)
        let searching = !terms.isEmpty
        let pinned = slots.prefix { $0.pinnedName != nil }
        if !pinned.isEmpty {
            let fold = fold(isFolded: arrangement.isPinnedFolded, searching: searching)
            items.append(.pinnedHeader(ConversationSectionSummary(pinned.map(\.row), fold: fold)))
            if fold != .folded { items.append(contentsOf: pinned.map { .row($0.row) }) }
        }
        let unpinned = slots.dropFirst(pinned.count)
        let automations = unpinned.prefix { $0.row.isAutomation }
        appendAutomations(automations, to: &items, arrangement: arrangement, searching: searching)
        let remaining = unpinned.dropFirst(automations.count)
        let chats = remaining.prefix { !$0.isSettled }
        if arrangement.mode == .projects {
            appendProjects(of: chats, to: &items, arrangement: arrangement, searching: searching, showsHostLabel: showsHostLabel)
        } else {
            if !items.isEmpty, !chats.isEmpty { items.append(.chatsHeader) }
            items.append(contentsOf: chats.map { .row($0.row) })
        }
        appendSettled(remaining.dropFirst(chats.count), to: &items, arrangement: arrangement, searching: searching)
        return items
    }

    private static func appendAutomations(_ automations: ArraySlice<Slot>, to items: inout [ConversationSidebarItem],
                                          arrangement: ConversationDrawerArrangement, searching: Bool) {
        guard !automations.isEmpty else { return }
        let fold = fold(isFolded: arrangement.isAutomationsFolded, searching: searching)
        items.append(.automationsHeader(ConversationSectionSummary(automations.map(\.row), fold: fold)))
        let shown: [ConversationSidebarRow] = switch fold {
        case .folded: []
        case .searching: automations.map(\.row)
        case .expanded: limited(automations, to: arrangement.automationRowLimit)
        }
        items.append(contentsOf: shown.map { .row($0) })
        if fold == .expanded, automations.count > shown.count {
            items.append(.moreAutomations(hiddenCount: automations.count - shown.count))
        }
    }

    private static func appendProjects(of chats: ArraySlice<Slot>, to items: inout [ConversationSidebarItem],
                                       arrangement: ConversationDrawerArrangement, searching: Bool, showsHostLabel: Bool) {
        var groups: [String: [Slot]] = [:]
        var projects: [String: Project] = [:]
        for slot in chats {
            guard let project = slot.project else { continue }
            groups[project.key, default: []].append(slot)
            projects[project.key] = project
        }
        let ordered: [(key: String, latest: Int64, slots: [Slot])] = groups
            .map { key, slots in (key: key, latest: slots.map(\.rank.recency).max() ?? .min, slots: slots) }
            .sorted { lhs, rhs in lhs.latest != rhs.latest ? lhs.latest > rhs.latest : lhs.key < rhs.key }
        for group in ordered {
            guard let project = projects[group.key] else { continue }
            let fold = fold(isFolded: arrangement.foldedProjects.contains(group.key), searching: searching)
            items.append(.project(ConversationProjectHeader(
                key: group.key,
                title: project.title,
                hostName: showsHostLabel ? project.hostName : nil,
                summary: ConversationSectionSummary(group.slots.map(\.row), fold: fold)
            )))
            guard fold != .folded else { continue }
            let limit = searching || arrangement.revealedProjects.contains(group.key)
                ? group.slots.count : arrangement.projectRowLimit ?? group.slots.count
            items.append(contentsOf: group.slots.prefix(limit).map { .row($0.row) })
            if group.slots.count > limit {
                items.append(.more(projectKey: group.key, hiddenCount: group.slots.count - limit))
            }
        }
    }

    private static func appendSettled(_ settled: ArraySlice<Slot>, to items: inout [ConversationSidebarItem],
                                      arrangement: ConversationDrawerArrangement, searching: Bool) {
        guard !settled.isEmpty else { return }
        let fold = fold(isFolded: arrangement.isSettledFolded, searching: searching)
        items.append(.settledHeader(ConversationSectionSummary(settled.map(\.row), fold: fold)))
        let limit: Int? = switch fold {
        case .searching: nil
        case .folded: 0
        case .expanded: arrangement.settledRowLimit
        }
        let shown = limited(settled, to: limit)
        items.append(contentsOf: shown.map { .row($0) })
        if fold == .expanded, settled.count > shown.count {
            items.append(.moreSettled(hiddenCount: settled.count - shown.count))
        }
    }

    private static func limited(_ slots: ArraySlice<Slot>, to limit: Int?) -> [ConversationSidebarRow] {
        guard let limit else { return slots.map(\.row) }
        return slots.enumerated().filter { $0.offset < limit || $0.element.row.isSelected }.map(\.element.row)
    }

    private static func fold(isFolded: Bool, searching: Bool) -> ConversationSectionFold {
        searching ? .searching : isFolded ? .folded : .expanded
    }

    private struct Project {
        let key: String
        let title: String
        let hostName: String?
    }

    private static func project(of thread: ConversationHeader, on host: ConversationSidebarHostInput,
                                condensedPaths: CondensedPathCache) -> Project {
        let hostScope = host.hostID.uuidString
        guard let identity = host.projects[thread.cwd] else {
            return Project(key: "\(hostScope)|directory|\(thread.cwd)",
                           title: condensedPaths.condensedPath(thread.cwd, remoteHomePath: host.remoteHomePath),
                           hostName: host.hostName)
        }
        return switch identity.kind {
        case .remote:
            Project(key: "remote|\(identity.key)", title: identity.name, hostName: nil)
        case .repository:
            Project(key: "\(hostScope)|repository|\(identity.key)", title: identity.name, hostName: host.hostName)
        case .directory:
            Project(key: "\(hostScope)|directory|\(identity.key)",
                    title: condensedPaths.condensedPath(identity.root, remoteHomePath: host.remoteHomePath),
                    hostName: host.hostName)
        }
    }

    static func matches(title: String, workingDirectory: String, hostName: String?, query: String) -> Bool {
        matches(title: title, workingDirectory: workingDirectory, hostName: hostName,
                terms: query.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private static func matches(_ row: ConversationSidebarRow, terms: [String]) -> Bool {
        matches(title: row.title, workingDirectory: row.workingDirectory,
                hostName: row.showsHostLabel ? row.hostName : nil, terms: terms)
    }

    private static func matches(title: String, workingDirectory: String, hostName: String?, terms: [String]) -> Bool {
        terms.allSatisfy { term in
            title.localizedStandardContains(term)
                || workingDirectory.localizedStandardContains(term)
                || hostName?.localizedStandardContains(term) == true
        }
    }

    private struct Slot {
        let row: ConversationSidebarRow
        let rank: ConversationDrawerRank
        let pinnedName: String?
        let isSettled: Bool
        let project: Project?

        private var sectionOrder: Int { row.isAutomation ? 0 : isSettled ? 2 : 1 }

        func precedes(_ other: Slot) -> Bool {
            switch (pinnedName, other.pinnedName) {
            case let (name?, otherName?):
                let order = name.localizedStandardCompare(otherName)
                if order != .orderedSame { return order == .orderedAscending }
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                if sectionOrder != other.sectionOrder { return sectionOrder < other.sectionOrder }
                if sectionOrder != 2, rank.tier != other.rank.tier { return rank.tier.rawValue < other.rank.tier.rawValue }
                if rank.recency != other.rank.recency { return rank.recency > other.rank.recency }
            }
            return row.id < other.row.id
        }
    }

    static func hostStates(hosts: [ConversationSidebarHostInput]) -> [ConversationSidebarHostState] {
        hosts.map { host in
            ConversationSidebarHostState(
                hostID: host.hostID,
                hostName: host.hostName,
                isLoading: host.isLoading,
                status: host.isGatewayRestarting ? .updating : host.errorMessage.map(ConversationSidebarHostStatus.failed),
                rowCount: host.threads.filter { !$0.isDelegatedAgent }.count,
                canLoadMore: host.canLoadMore,
                hasDiscardedHeaders: host.hasDiscardedHeaders,
                unloadedPins: host.unloadedPins,
                showsHostLabel: showsHostLabels(targetCount: hosts.count)
            )
        }
    }

    static func title(for header: ConversationHeader, pinnedName: String?) -> String {
        if let pinnedName { return pinnedName }
        return header.displayTitle
    }
}
