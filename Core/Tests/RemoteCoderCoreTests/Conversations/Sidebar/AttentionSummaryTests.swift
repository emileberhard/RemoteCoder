import Foundation
import Testing
@testable import RemoteCoderCore

struct AttentionSummaryTests {
    private let mini = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let book = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func conversationsThatNeedYouComeBeforeRunningOnesWithinTheLimit() throws {
        let summary = AttentionSummary(hosts: [
            host(mini, name: "Mini", threads: [
                try thread("running-new", updatedAt: 900),
                try thread("asks", updatedAt: 100),
                try thread("idle", updatedAt: 950),
            ], activity: ["running-new": .working, "asks": .working, "idle": .idle], questions: ["asks": asks(2)]),
            host(book, name: "Book", threads: [
                try thread("waits", updatedAt: 200),
                try thread("running-old", updatedAt: 300),
            ], activity: ["waits": .waiting, "running-old": .working]),
        ], limit: 3, at: now)

        #expect(summary.entries.map(\.address.threadID) == ["waits", "asks", "running-new"])
        #expect(summary.entries.map(\.kind) == [.input, .question, .running])
        #expect(summary.needsYouCount == 2)
        #expect(summary.runningCount == 2)
        #expect(summary.showsHostNames)
    }

    @Test func pendingQuestionsStayUnknownUntilSomeCountIsKnown() throws {
        let unread = AttentionSummary(hosts: [
            host(mini, name: "Mini", threads: [try thread("a", updatedAt: 1)], activity: ["a": .idle]),
        ], limit: 8, at: now)
        #expect(unread.pendingQuestions == nil)
        #expect(unread.badgeLabel == nil)

        let answered = AttentionSummary(hosts: [
            host(mini, name: "Mini", threads: [try thread("a", updatedAt: 1)], activity: ["a": .idle], questions: ["a": []]),
        ], limit: 8, at: now)
        #expect(answered.pendingQuestions == 0)
        #expect(answered.badgeLabel == nil)

        let pending = AttentionSummary(hosts: [
            host(mini, name: "Mini", threads: [try thread("a", updatedAt: 1)], activity: ["a": .idle], questions: ["a": asks(2)]),
            host(book, name: "Book", threads: [], activity: [:], questions: ["not-listed": asks(1)]),
        ], limit: 8, at: now)
        #expect(pending.pendingQuestions == 3)
        #expect(pending.badgeLabel == "3")
    }

    @Test func onlyUncoveredRequestsNeedYouOrCountAndTheNextFutureExpirySchedulesARecheck() throws {
        let automatic: Int64 = 1_000_000 - ConversationSettlement.automaticAfter
        let ids = ["old-waits", "old-asks", "settled-asks", "old-runs", "waits", "asks", "undated", "mixed", "revived",
                   "held"]
        var marks = ConversationMarks(schemaVersion: 2, revision: 1, readBaseline: 0, threads: [:])
        for id in ids { marks.threads[id] = ThreadMarks(revision: 1, seenThrough: 1) }
        marks.threads["settled-asks"]?.settlement = .settled(through: 999_000)
        marks.threads["held"]?.settlement = .active(through: 2)
        let summary = AttentionSummary(hosts: [
            host(mini, name: "Mini", threads: try ids.map { try thread($0, updatedAt: 1) },
                 activity: ["old-waits": .waiting, "old-runs": .working, "waits": .waiting, "undated": .waiting,
                            "revived": .waiting],
                 questions: ["old-asks": [automatic - 5], "settled-asks": asks(2, at: 998_000),
                             "asks": asks(8, at: automatic + 20), "mixed": [automatic - 100, 999_900],
                             "revived": [automatic - 1], "held": [automatic - 50], "not-listed": asks(4)],
                 waitingSince: ["old-waits": automatic, "waits": automatic + 30, "revived": 999_950],
                 marks: marks),
        ], limit: 10, at: now)

        let needsYou = Dictionary(uniqueKeysWithValues: summary.entries.filter(\.kind.needsYou).map { ($0.address.threadID, $0.kind) })
        #expect(needsYou == ["waits": .input, "asks": .question, "undated": .input, "mixed": .question,
                             "revived": .input, "held": .question])
        #expect(summary.runningCount == 1)
        #expect(summary.pendingQuestions == 14)
        #expect(summary.nextAutomaticSettlement == Date(timeIntervalSince1970: 1_000_020))
    }

    @Test func unknownActivityIsReportedPerHostInsteadOfCountedAsIdle() throws {
        let summary = AttentionSummary(hosts: [
            host(mini, name: "Mini", threads: [try thread("a", updatedAt: 1), try thread("b", updatedAt: 2)],
                 activity: ["a": .unknown, "b": .working]),
            host(book, name: "Book", threads: [try thread("c", updatedAt: 1)], activity: [:]),
            host(book, name: "Book", threads: [try thread("d", updatedAt: 1)], activity: ["d": .idle]),
        ], limit: 8, at: now)

        #expect(summary.hostsWithUnknownStatus == ["Mini", "Book"])
        #expect(summary.runningCount == 1)
        #expect(summary.needsYouCount == 0)
    }

    @Test func sameThreadOnTwoHostsStaysTwoAddressesAndAgentsAreSkipped() throws {
        var agent = try thread("agent", updatedAt: 5)
        agent.agentRelation = .init(parentThreadId: "shared", parentAccountId: nil, agentId: "launcher:run")
        let shared = try thread("shared", updatedAt: 1)
        let summary = AttentionSummary(hosts: [
            host(mini, name: "Mini", threads: [shared, agent], activity: ["shared": .working, "agent": .working]),
        ], limit: 8, at: now)
        let twoHosts = AttentionSummary(hosts: [
            host(mini, name: "Mini", threads: [shared], activity: ["shared": .working]),
            host(book, name: "Book", threads: [shared], activity: ["shared": .working]),
        ], limit: 8, at: now)

        #expect(summary.entries.map(\.address.threadID) == ["shared"])
        #expect(summary.showsHostNames == false)
        #expect(Set(twoHosts.entries.map(\.address)) == [
            ConversationAddress(hostID: mini, threadID: "shared"),
            ConversationAddress(hostID: book, threadID: "shared"),
        ])
    }

    private func host(
        _ hostID: UUID,
        name: String,
        threads: [ConversationHeader],
        activity: [String: CodexGatewayDaemon.ActivityState],
        questions: [String: [Int64]] = [:],
        waitingSince: [String: Int64] = [:],
        marks: ConversationMarks = ConversationMarksReplica().effective
    ) -> ConversationSidebarHostInput {
        ConversationSidebarHostInput(
            hostID: hostID,
            hostName: name,
            threads: threads,
            marks: marks,
            remoteHomePath: nil,
            activityByThreadID: activity,
            activeThreadID: nil,
            loadingThreadID: nil,
            isLoading: false,
            errorMessage: nil,
            questionAskTimesByThreadID: questions,
            waitingSinceByThreadID: waitingSince
        )
    }

    private func asks(_ count: Int, at askedAt: Int64 = 999_000) -> [Int64] {
        Array(repeating: askedAt, count: count)
    }

    private func thread(_ id: String, updatedAt: Int64) throws -> ConversationHeader {
        try ThreadFixture.basic(id, updatedAt: updatedAt, preview: "Conversation \(id)",
                                fields: ["lastTurnCompletedAt": updatedAt])
    }
}
