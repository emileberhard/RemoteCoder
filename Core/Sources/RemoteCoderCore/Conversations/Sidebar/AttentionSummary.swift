import Foundation

struct AttentionSummary: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case question
        case input
        case running

        var needsYou: Bool { self != .running }
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let address: ConversationAddress
        let title: String
        let hostName: String
        let kind: Kind

        var id: String { address.id }
    }

    let entries: [Entry]
    let needsYouCount: Int
    let runningCount: Int
    let pendingQuestions: Int?
    let hostsWithUnknownStatus: [String]
    let showsHostNames: Bool
    let nextAutomaticSettlement: Date?

    init(hosts: [ConversationSidebarHostInput], limit: Int, at now: Date) {
        let now = Int64(now.timeIntervalSince1970)
        var needsYou: [(entry: Entry, updatedAt: Int64)] = []
        var running: [(entry: Entry, updatedAt: Int64)] = []
        var unknownHosts: [String] = []
        var pending: Int?
        var nextSettlement: Int64?
        for host in hosts {
            var openQuestions: [String: Int] = [:]
            var hasUnknownStatus = false
            for thread in host.threads where !thread.isDelegatedAgent {
                let activity = host.activityByThreadID[thread.id]
                if activity == nil || activity == .unknown { hasUnknownStatus = true }
                let askTimes = host.questionAskTimesByThreadID[thread.id] ?? []
                guard !askTimes.isEmpty || activity == .waiting || activity == .working else { continue }
                let waitingSince = host.waitingSinceByThreadID[thread.id]
                let openQuestionTimes = askTimes.filter { !host.marks.coversRequest(madeAt: $0, in: thread, at: now) }
                openQuestions[thread.id] = openQuestionTimes.count
                var openRequestTimes = openQuestionTimes
                if activity == .waiting, let waitingSince, !host.marks.coversRequest(madeAt: waitingSince, in: thread, at: now) {
                    openRequestTimes.append(waitingSince)
                }
                for settlesAt in openRequestTimes.map({ $0 + ConversationSettlement.automaticAfter }) where settlesAt > now {
                    nextSettlement = min(nextSettlement ?? settlesAt, settlesAt)
                }
                let rank = ConversationDrawerRank(thread, activity: activity, questionAskTimes: askTimes,
                                                  waitingSince: waitingSince, marks: host.marks, settlementEdit: 0, at: now)
                let kind: Kind
                switch rank.tier {
                case .needsYou: kind = openQuestionTimes.isEmpty ? .input : .question
                case .running: kind = .running
                case .unread, .recent: continue
                }
                let entry = Entry(
                    address: ConversationAddress(hostID: host.hostID, threadID: thread.id),
                    title: ConversationSidebarProjection.title(for: thread, pinnedName: host.marks.pinName(for: thread.id)),
                    hostName: host.hostName,
                    kind: kind
                )
                if kind.needsYou { needsYou.append((entry, thread.updatedAt)) } else { running.append((entry, thread.updatedAt)) }
            }
            for (threadID, askTimes) in host.questionAskTimesByThreadID {
                pending = (pending ?? 0) + (openQuestions[threadID] ?? askTimes.count)
            }
            if hasUnknownStatus, !unknownHosts.contains(host.hostName) { unknownHosts.append(host.hostName) }
        }
        let newestFirst: ((entry: Entry, updatedAt: Int64), (entry: Entry, updatedAt: Int64)) -> Bool = {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.entry.id < $1.entry.id
        }
        entries = Array((needsYou.sorted(by: newestFirst) + running.sorted(by: newestFirst)).prefix(limit).map(\.entry))
        needsYouCount = needsYou.count
        runningCount = running.count
        pendingQuestions = pending
        hostsWithUnknownStatus = unknownHosts
        showsHostNames = hosts.count > 1
        nextAutomaticSettlement = nextSettlement.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    var badgeLabel: String? {
        guard let pendingQuestions, pendingQuestions > 0 else { return nil }
        return String(pendingQuestions)
    }
}
