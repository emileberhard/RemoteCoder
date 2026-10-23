import Foundation

enum ConversationDrawerMode: String, CaseIterable, Sendable {
    case priority
    case projects
}

struct ConversationDrawerArrangement: Equatable, Sendable {
    static let initialSettledRowLimit = 10
    static let settledRowsRevealedPerStep = 25
    static let initialAutomationRowLimit = 5

    var mode: ConversationDrawerMode = .priority
    var unreadOnly = false
    var isPinnedFolded = false
    var isAutomationsFolded = false
    var isSettledFolded = true
    var foldedProjects: Set<String> = []
    var revealedProjects: Set<String> = []
    var projectRowLimit: Int?
    var automationRowLimit: Int? = Self.initialAutomationRowLimit
    var settledRowLimit: Int? = Self.initialSettledRowLimit
    var query = ""
}

struct ConversationDrawerRank: Equatable, Sendable {
    enum Tier: Int, Sendable {
        case needsYou
        case running
        case unread
        case recent
    }

    enum SettlementMark: Equatable, Sendable {
        case unavailable
        case automatic
        case explicit(ConversationSettlement, isPinned: Bool)

        init(of threadID: String, in marks: ConversationMarks) {
            guard marks.offersSettlement else { self = .unavailable; return }
            guard let thread = marks.threads[threadID], let settlement = thread.settlement else { self = .automatic; return }
            guard case .settled = settlement else { self = .explicit(settlement, isPinned: false); return }
            self = .explicit(settlement, isPinned: thread.pinName != nil)
        }
    }

    let tier: Tier
    let recency: Int64
    let isUnread: Bool
    let isSettled: Bool
    let settlementEdit: Int
    let settlementMark: SettlementMark

    init(_ thread: ConversationHeader, activity: CodexGatewayDaemon.ActivityState?, questionAskTimes: [Int64],
         waitingSince: Int64?, marks: ConversationMarks, settlementEdit: Int, at now: Int64) {
        let isUnread = marks.isUnread(thread)
        let needsYou = activity == .waiting && !marks.coversRequest(madeAt: waitingSince, in: thread, at: now)
            || questionAskTimes.contains { !marks.coversRequest(madeAt: $0, in: thread, at: now) }
        let isSettled = marks.isSettled(thread, isLive: needsYou || activity == .working, at: now)
        tier = if needsYou {
            .needsYou
        } else if activity == .working {
            .running
        } else if isUnread {
            .unread
        } else {
            .recent
        }
        recency = thread.latestActivityAt
        self.isUnread = isUnread
        self.isSettled = isSettled
        self.settlementEdit = settlementEdit
        settlementMark = SettlementMark(of: thread.id, in: marks)
    }

    var isLive: Bool { tier == .needsYou || tier == .running }

    func holdsSettlement(edit: Int, mark: SettlementMark) -> Bool {
        settlementEdit == edit && settlementMark == mark
    }
}

struct ConversationDrawerLayout: Equatable, Sendable {
    let capturedAt: Int64
    private let ranksByTarget: [ExecutionTarget: [String: ConversationDrawerRank]]

    init(capturedAt: Int64, ranksByTarget: [ExecutionTarget: [String: ConversationDrawerRank]]) {
        self.capturedAt = capturedAt
        self.ranksByTarget = ranksByTarget
    }

    static func live(at date: Date) -> Self {
        Self(capturedAt: Int64(date.timeIntervalSince1970), ranksByTarget: [:])
    }

    func admitting(_ arrivals: [ExecutionTarget: [String: ConversationDrawerRank]]) -> Self {
        var ranks = ranksByTarget
        for (target, arriving) in arrivals {
            ranks[target, default: [:]].merge(arriving) { _, admitted in admitted }
        }
        return Self(capturedAt: capturedAt, ranksByTarget: ranks)
    }

    func ranks(on target: ExecutionTarget) -> [String: ConversationDrawerRank] {
        ranksByTarget[target] ?? [:]
    }
}
