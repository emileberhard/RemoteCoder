import Foundation
import Testing
@testable import RemoteCoderCore

/// The merged drawer is a pure projection, so host-qualified identity,
/// ordering and per-host failure attribution are testable without a gateway.
struct ConversationSidebarProjectionTests {
    private let mini = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let book = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let openedAt = Date(timeIntervalSince1970: 1_000_000)
    private var live: ConversationDrawerLayout { .live(at: openedAt) }
    private let asked: Int64 = 999_000

    @Test func attachmentEnvelopesStayOutOfSidebarTitlesAndPreviews() throws {
        let prompt = """
        <remotecoder_pasted_text_v1>
        [{"id":"77777777-2222-3333-4444-555555555555","text":"Readable sidebar title\\nMore pasted text"}]
        </remotecoder_pasted_text_v1>
        """
        let rows = sidebarRows(hosts: [host(mini, name: "Mini", threads: [try thread("t", updatedAt: 1, preview: prompt)])])
        #expect(rows.first?.title == "Readable sidebar title")
        #expect(rows.first?.preview == "Readable sidebar title")
    }

    @Test func confirmedAgentsAreHiddenOnlyOnTheirOwningHost() throws {
        var child = try thread("shared", updatedAt: 200, preview: "Agent")
        child.agentRelation = .init(parentThreadId: "root", parentAccountId: nil, agentId: "launcher:run")
        let other = try thread("shared", updatedAt: 200, preview: "Ordinary conversation")
        let rows = sidebarRows(hosts: [host(mini, name: "Mini", threads: [child]), host(book, name: "Book", threads: [other])])
        #expect(rows.count == 1)
        #expect(rows.first?.address.hostID == book)
    }

    @Test func sameThreadIDOnTwoHostsStaysTwoIndependentRows() throws {
        let shared = try thread("0199", updatedAt: 500, preview: "Shared id")
        let rows = sidebarRows(hosts: [
            host(mini, name: "Mac Mini", threads: [shared], marks: marks(pins: ["0199": "Mini pin"]), activeThreadID: "0199"),
            host(book, name: "MacBook", threads: [shared], activeThreadID: "0199"),
        ])

        #expect(rows.count == 2)
        #expect(Set(rows.map(\.address)) == [
            ConversationAddress(hostID: mini, threadID: "0199"),
            ConversationAddress(hostID: book, threadID: "0199"),
        ])

        let miniRow = try #require(rows.first { $0.address.hostID == mini })
        let bookRow = try #require(rows.first { $0.address.hostID == book })
        // One host's pin and one host's selection must not leak into the other.
        #expect(miniRow.isPinned)
        #expect(miniRow.title == "Mini pin")
        #expect(bookRow.isPinned == false)
        #expect(bookRow.title == "Shared id")
        #expect(miniRow.isSelected)
        #expect(bookRow.isSelected == false)
        #expect(miniRow.id != bookRow.id)
    }

    @Test func rowsMergeByPinThenRecencyThenStableAddress() throws {
        let rows = sidebarRows(hosts: [
            host(mini, name: "Mac Mini", threads: [
                try thread("mini-old", updatedAt: 100),
                try thread("mini-pinned", updatedAt: 50),
                try thread("tie", updatedAt: 300),
            ], marks: marks(pins: ["mini-pinned": "Keep"])),
            host(book, name: "MacBook", threads: [
                try thread("book-new", updatedAt: 400),
                try thread("tie", updatedAt: 300),
            ]),
        ])

        #expect(rows.map(\.address.threadID) == ["mini-pinned", "book-new", "tie", "tie", "mini-old"])
        // Equal timestamps across hosts must not reshuffle between refreshes.
        let ties = rows.filter { $0.address.threadID == "tie" }
        #expect(ties.map(\.address.id) == ties.map(\.address.id).sorted())
    }

    @Test func refreshedUnchangedHostsProjectEqualItemsAndDisplayedChangesDoNot() throws {
        func hosts(bookPreview: String) throws -> [ConversationSidebarHostInput] {
            [
                host(mini, name: "Mac Mini", threads: [try thread("a", updatedAt: 1)], marks: marks(pins: ["a": "Keep"]),
                     activityByThreadID: ["a": .working]),
                host(book, name: "MacBook", threads: [try thread("b", updatedAt: 2, preview: bookPreview)],
                     marks: marks(pins: ["b": "Release"])),
            ]
        }
        let opened = items(try hosts(bookPreview: "Plan"))
        #expect(items(try hosts(bookPreview: "Plan")) == opened)
        #expect(items(try hosts(bookPreview: "Plan the release")) != opened)
    }

    @Test func oneHostKeepsTheDrawerLookingSingleHost() throws {
        let rows = sidebarRows(hosts: [host(mini, name: "Mac Mini", threads: [try thread("a", updatedAt: 1)])])
        #expect(rows.map(\.showsHostLabel) == [false])

        let multi = sidebarRows(hosts: [
            host(mini, name: "Mac Mini", threads: [try thread("a", updatedAt: 1)]),
            host(book, name: "MacBook", threads: [try thread("b", updatedAt: 2)]),
        ])
        #expect(multi.map(\.showsHostLabel) == [true, true])
        #expect(multi.map(\.hostName) == ["MacBook", "Mac Mini"])
    }

    @Test func aFailingHostKeepsItsCachedRowsAndOwnsTheError() throws {
        let hosts = [
            host(mini, name: "Mac Mini", threads: [try thread("mini-a", updatedAt: 10)]),
            host(book, name: "MacBook", threads: [try thread("book-a", updatedAt: 5)],
                 isLoading: true, errorMessage: "MacBook (macbook:8787) is unreachable"),
        ]

        let rows = sidebarRows(hosts: hosts)
        #expect(rows.count == 2)
        // The unreachable host's cached row survives its failure.
        #expect(rows.contains { $0.address.hostID == book })

        let states = ConversationSidebarProjection.hostStates(hosts: hosts)
        #expect(states.map(\.hostID) == [mini, book])
        #expect(states[0].status == nil)
        #expect(states[1].status == .failed("MacBook (macbook:8787) is unreachable"))
        #expect(states[1].isLoading)
        #expect(states.map(\.rowCount) == [1, 1])
    }

    @Test func aRestartingHostReportsUpdatingInsteadOfItsConnectionError() throws {
        let hosts = [
            host(mini, name: "Mac Mini", threads: [try thread("mini-a", updatedAt: 10)],
                 errorMessage: "Codex gateway is restarting.", isGatewayRestarting: true),
            host(book, name: "MacBook", threads: [try thread("book-a", updatedAt: 5)], isGatewayRestarting: true),
        ]

        let states = ConversationSidebarProjection.hostStates(hosts: hosts)
        #expect(states.map(\.status) == [.updating, .updating])
        #expect(sidebarRows(hosts: hosts).count == 2)
    }

    @Test func rowStateComesFromTheOwningHostOnly() throws {
        let rows = sidebarRows(hosts: [
            host(mini, name: "Mac Mini", threads: [try thread("busy", updatedAt: 9, preview: "")],
                 remoteHomePath: "/Users/developer", activityByThreadID: ["busy": .working],
                 activeThreadID: "busy", loadingThreadID: "busy"),
            host(book, name: "MacBook", threads: [try thread("busy", updatedAt: 8)]),
        ], selectedHostID: book)

        let miniRow = try #require(rows.first { $0.address.hostID == mini })
        let bookRow = try #require(rows.first { $0.address.hostID == book })
        #expect(miniRow.activity == .working)
        #expect(miniRow.isLoading)
        #expect(miniRow.title == "(untitled)")
        #expect(bookRow.activity == nil)
        #expect(bookRow.isLoading == false)
        // The hidden host's open conversation is not the current one.
        #expect(miniRow.isSelected == false)
    }

    @Test func priorityPutsQuestionsThenRunningThenUnreadAboveRecentWork() throws {
        let hosts = [host(mini, name: "Mini", threads: [
            try thread("recent", updatedAt: 900), try thread("unread", updatedAt: 500),
            try thread("working", updatedAt: 300), try thread("waiting", updatedAt: 200),
            try thread("question", updatedAt: 100), try thread("old", updatedAt: 50),
        ], marks: marks(readBaseline: 400, seen: ["recent": 900]),
           activityByThreadID: ["working": .working, "waiting": .waiting, "old": .unknown],
           questions: ["question": [asked]])]

        #expect(outline(hosts) == ["waiting", "question", "working", "unread", "recent", "old"])
        #expect(sidebarRows(hosts: hosts).filter(\.isUnread).map(\.address.threadID) == ["unread"])
    }

    @Test func doneSuggestionsBadgeRowsWithoutChangingTheirRank() throws {
        var suggested = marks(schemaVersion: 3, readBaseline: 900_005)
        for id in ["question", "waiting", "working", "unread", "done"] {
            suggested.threads[id] = ThreadMarks(doneThrough: 900_006)
        }
        let hosts = [host(mini, name: "Mini", threads: [
            try thread("question", updatedAt: 900_001), try thread("waiting", updatedAt: 900_002),
            try thread("working", updatedAt: 900_003), try thread("unread", updatedAt: 900_006),
            try thread("recent", updatedAt: 800_000), try thread("done", updatedAt: 900_004),
        ], marks: suggested, activityByThreadID: ["waiting": .waiting, "working": .working],
           questions: ["question": [asked]])]

        #expect(outline(hosts) == ["waiting", "question", "working", "unread", "done", "recent"])
        #expect(sidebarRows(hosts: hosts).filter(\.isProbablyDone).map(\.address.threadID) == ["unread", "done"])
    }

    @Test func doneBadgeUpdatesInPlaceAndClearsOnNewActivity() throws {
        let threads = [try thread("a", updatedAt: 900_000), try thread("b", updatedAt: 800_000)]
        let opened = [host(mini, name: "Mini", threads: threads, marks: marks(schemaVersion: 3))]
        let layout = ConversationSidebarProjection.layout(hosts: opened, at: openedAt)
        var suggested = opened[0].marks
        suggested.threads["a"] = ThreadMarks(doneThrough: 900_000)
        let updated = [host(mini, name: "Mini", threads: threads, marks: suggested)]
        let admitted = ConversationSidebarProjection.admittingLayout(hosts: updated, layout: layout)

        #expect(outline(updated, layout: admitted) == ["a", "b"])
        #expect(sidebarRows(hosts: updated, layout: admitted).first?.isProbablyDone == true)
        let reopened = ConversationSidebarProjection.layout(hosts: updated, at: openedAt)
        #expect(outline(updated, layout: reopened) == ["a", "b"])
        let newer = [host(mini, name: "Mini", threads: [try thread("a", updatedAt: 900_001), threads[1]], marks: suggested)]
        #expect(sidebarRows(hosts: newer, layout: reopened).first?.isProbablyDone == false)
    }

    @Test func doneBadgeStaysOffPinnedPurposeAndSettledRows() throws {
        var suggested = marks(schemaVersion: 3, pins: ["pinned": "Keep"], purposes: ["automation": .automation],
                              settlements: ["settled": .settled(through: 900_000)])
        for id in ["pinned", "automation", "settled", "old", "done"] {
            suggested.threads[id, default: ThreadMarks()].doneThrough = 900_000
        }
        let hosts = [host(mini, name: "Mini", threads: [
            try thread("pinned", updatedAt: 900_000), try thread("automation", updatedAt: 900_000),
            try thread("settled", updatedAt: 900_000), try thread("old", updatedAt: 100),
            try thread("done", updatedAt: 900_000),
        ], marks: suggested)]
        var expanded = ConversationDrawerArrangement()
        expanded.isSettledFolded = false
        let rows = sidebarRows(hosts: hosts, arrangement: expanded)
        #expect(rows.count == 5)
        #expect(rows.filter(\.isProbablyDone).map(\.address.threadID) == ["done"])
        #expect(rows.filter(\.isSettled).map(\.address.threadID) == ["settled", "old"])
    }

    @Test func capturedRanksHoldUntilTheDrawerReopens() throws {
        let newer = try thread("newer", updatedAt: 200)
        let opened = [host(mini, name: "Mini", threads: [try thread("old", updatedAt: 100), newer, try thread("idle", updatedAt: 50)])]
        let layout = ConversationSidebarProjection.layout(hosts: opened, at: openedAt)
        #expect(outline(opened, layout: layout) == ["newer", "old", "idle"])

        let finished = try thread("old", updatedAt: 1_000_000, preview: "Finished")
        let changed = [host(mini, name: "Mini", threads: [finished, newer, try thread("idle", updatedAt: 50)],
                            activityByThreadID: ["idle": .working])]
        #expect(outline(changed, layout: layout) == ["newer", "old", "idle"])
        let held = sidebarRows(hosts: changed, layout: layout)
        #expect(held.last?.activity == .working)
        #expect(held.dropFirst().first?.title == "Finished")

        let reopened = ConversationSidebarProjection.layout(hosts: changed, at: openedAt)
        #expect(outline(changed, layout: reopened) == ["idle", "old", "newer"])
    }

    @Test func rowsThatArriveWhileOpenHoldTheirFirstPlace() throws {
        let captured = [try thread("a", updatedAt: 100), try thread("b", updatedAt: 300)]
        let layout = ConversationSidebarProjection.layout(hosts: [host(mini, name: "Mini", threads: captured)], at: openedAt)
        let arrived = captured + [try thread("c", updatedAt: 200), try thread("d", updatedAt: 50)]
        let hosts = [host(mini, name: "Mini", threads: arrived, activityByThreadID: ["d": .working])]
        let admitted = ConversationSidebarProjection.admittingLayout(hosts: hosts, layout: layout)
        #expect(outline(hosts, layout: admitted) == ["d", "b", "c", "a"])
        let changed = [host(mini, name: "Mini", threads: captured + [
            try thread("c", updatedAt: 900), try thread("d", updatedAt: 10)
        ], activityByThreadID: ["c": .waiting])]
        let readmitted = ConversationSidebarProjection.admittingLayout(hosts: changed, layout: admitted)
        #expect(readmitted == admitted)
        #expect(outline(changed, layout: readmitted) == ["d", "b", "c", "a"])
        #expect(sidebarRows(hosts: changed, layout: readmitted).first { $0.address.threadID == "c" }?.activity == .waiting)
    }

    @Test(arguments: [
        (["a", "b"], ["b", "a"], ["b"]),
        (["a", "b", "c", "d"], ["d", "a", "b", "c"], ["d"]),
        (["a", "b"], ["new", "a", "b"], []),
        (["a", "b", "c"], ["a", "c"], []),
        (["a", "b"], ["a", "b"], []),
        (["a", "b", "c"], ["c", "b", "a"], ["c"])
    ])
    func risingRowsIgnoreInsertionsAndRemovals(old: [String], new: [String], expected: [String]) throws {
        func rows(_ ids: [String]) throws -> [ConversationSidebarItem] {
            items([host(mini, name: "Mini", threads: try ids.enumerated().map {
                try thread($0.element, updatedAt: Int64(ids.count - $0.offset))
            })])
        }
        let expectedIDs = Set(expected.map { ConversationAddress(hostID: mini, threadID: $0).id })
        #expect(ConversationSidebarItem.risingRowIDs(from: try rows(old), to: try rows(new)) == expectedIDs)
    }

    @Test func dateLabelsChangeWhenTheSnapshotDayChanges() throws {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: openedAt)
        let next = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let hosts = [host(mini, name: "Mini", threads: [try thread("a", updatedAt: Int64(start.timeIntervalSince1970))])]
        let dateLabels = ConversationSidebarDateCache()
        func row(on date: Date) throws -> ConversationSidebarRow {
            let projected = ConversationSidebarProjection.items(hosts: hosts, selectedHostID: mini, layout: live,
                arrangement: .init(), condensedPaths: CondensedPathCache(), now: date, dateLabels: dateLabels)
            return try #require(projected.compactMap { item in if case let .row(row) = item { row } else { nil } }.first)
        }
        #expect(try row(on: start).dateLabel != "Yesterday")
        #expect(try row(on: next).dateLabel == "Yesterday")
    }

    @Test func pinsMoveImmediatelyAndUnpinnedRowsReturnToTheirCapturedPlace() throws {
        let threads = [try thread("x", updatedAt: 100), try thread("y", updatedAt: 200), try thread("z", updatedAt: 300)]
        let layout = ConversationSidebarProjection.layout(hosts: [host(mini, name: "Mini", threads: threads)], at: openedAt)

        let pinned = [host(mini, name: "Mini", threads: threads, marks: marks(pins: ["x": "Beta", "y": "alpha"]))]
        #expect(outline(pinned, layout: layout) == ["[pinned]", "y", "x", "[chats]", "z"])

        let unpinned = [host(mini, name: "Mini", threads: threads, marks: marks(pins: ["x": "Beta"]))]
        #expect(outline(unpinned, layout: layout) == ["[pinned]", "x", "[chats]", "z", "y"])
        #expect(outline([host(mini, name: "Mini", threads: threads)], layout: layout) == ["z", "y", "x"])
        #expect(outline([host(mini, name: "Mini", threads: [])]).isEmpty)
    }

    @Test func probesShowOnlyWhileLiveAndAutomationsKeepExplicitUnread() throws {
        let threads = [try thread("probe", updatedAt: 700), try thread("probe-live", updatedAt: 600),
                       try thread("automation", updatedAt: 500), try thread("flagged", updatedAt: 400)]
        var flags = marks(readBaseline: 100, purposes: ["probe": .probe, "probe-live": .probe,
                                                         "automation": .automation, "flagged": .automation])
        flags.threads["flagged"]?.markedUnread = true
        let rows = sidebarRows(hosts: [host(mini, name: "Mini", threads: threads, marks: flags,
                                            activityByThreadID: ["probe-live": .working])])

        #expect(rows.map(\.address.threadID) == ["probe-live", "flagged", "automation"])
        #expect(rows.map(\.isUnread) == [false, true, false])
    }

    @Test(arguments: [ConversationDrawerMode.priority, .projects])
    func automationRunsGroupSeparatelyWhilePinsAndSelectionKeepTheirIdentity(mode: ConversationDrawerMode) throws {
        let threads = try ["user", "automatic", "pinned", "selected"].map { try thread($0, updatedAt: 900_000) }
        let flags = marks(pins: ["pinned": "Keep"], purposes: [
            "automatic": .automation, "pinned": .automation, "selected": .automation,
        ])
        let hosts = [host(mini, name: "Mini", threads: threads, marks: flags,
                          activityByThreadID: ["automatic": .working], activeThreadID: "selected")]
        var arrangement = ConversationDrawerArrangement()
        arrangement.mode = mode
        let projected = items(hosts, arrangement: arrangement)
        let sections = ConversationSidebarSections.sections(of: projected)
        let automation = try #require(sections.first { $0.id == "automations" })
        #expect(automation.rows.map(\.address.threadID) == ["automatic", "selected"])
        #expect(automation.rows.allSatisfy { $0.isAutomation })
        #expect(automation.rows.last?.isSelected == true)
        let pinned = try #require(sections.first { $0.id == "pinned" }?.rows.first)
        #expect(pinned.isAutomation && pinned.isPinned)
        #expect(sections.flatMap(\.rows).map(\.address.threadID).count == 4)
        #expect(sections.last?.id == "automations")
        arrangement.isAutomationsFolded = true
        #expect(items(hosts, arrangement: arrangement).contains(.automationsHeader(ConversationSectionSummary(
            fold: .folded, rowCount: 2, unreadCount: 0, liveActivity: .working))))
        let unpinned = [host(mini, name: "Mini", threads: threads, marks: marks(purposes: ["pinned": .automation]))]
        #expect(sidebarRows(hosts: unpinned).first { $0.address.threadID == "pinned" }?.id == pinned.id)
    }

    @Test(arguments: [ConversationDrawerMode.priority, .projects])
    func settledAutomationsStayInTheirSectionAndSearchRevealsFoldedMatches(mode: ConversationDrawerMode) throws {
        let flags = marks(schemaVersion: 3, purposes: ["automatic": .automation],
                          settlements: ["automatic": .settled(through: 900_000), "settled": .settled(through: 900_000)])
        let hosts = [host(mini, name: "Mini", threads: [
            try thread("user", updatedAt: 900_000),
            try thread("automatic", updatedAt: 100, preview: "Daily report"),
            try thread("settled", updatedAt: 900_000),
        ], marks: flags, activeThreadID: "automatic")]
        var arrangement = ConversationDrawerArrangement(mode: mode)
        let sections = ConversationSidebarSections.sections(of: items(hosts, arrangement: arrangement))
        #expect(sections.map(\.id).suffix(2) == ["automations", "settled"])
        let row = try #require(sections.first { $0.id == "automations" }?.rows.first)
        #expect(row.isSelected && row.isAutomation && row.isSettled)
        #expect(sections.last?.rows.isEmpty == true)
        #expect(try settlement(of: "automatic", on: hosts[0]) == .settled)

        arrangement.isAutomationsFolded = true
        let folded = items(hosts, arrangement: arrangement)
        #expect(folded.contains(.automationsHeader(ConversationSectionSummary(
            fold: .folded, rowCount: 1, unreadCount: 0, liveActivity: nil))))
        #expect(!folded.contains { if case let .row(row) = $0 { row.isAutomation } else { false } })
        #expect(ConversationSidebarSections.sections(of: folded).first { $0.id == "automations" }?.rows.isEmpty == true)
        arrangement.query = "daily"
        let searched = items(hosts, arrangement: arrangement)
        #expect(searched == [.automationsHeader(ConversationSectionSummary(
            fold: .searching, rowCount: 1, unreadCount: 0, liveActivity: nil)), .row(row)])
        let foldedHeader = try #require(folded.first { $0.id == .automationsHeader })
        #expect(searched[0].keepingFold(of: foldedHeader) == .automationsHeader(
            ConversationSectionSummary(fold: .folded, rowCount: 1, unreadCount: 0, liveActivity: nil)))
        arrangement.query = "missing"
        #expect(items(hosts, arrangement: arrangement).isEmpty)
    }

    @Test func datedRequestsNeedYouOnlyWhileNoSettlementCoversThem() throws {
        let threads = [
            try thread("stale-wait", updatedAt: 40), try thread("stale-question", updatedAt: 35),
            try thread("fresh-question", updatedAt: 30), try thread("undated-wait", updatedAt: 25),
            try thread("settled-before", updatedAt: 800_000), try thread("asked-after", updatedAt: 800_000),
            try thread("pinned-wait", updatedAt: 20), try thread("undated-settled", updatedAt: 700_000),
        ]
        let settledMarks = marks(schemaVersion: 2, pins: ["pinned-wait": "Keep"], settlements: [
            "settled-before": .settled(through: 900_000), "asked-after": .settled(through: 900_000),
            "undated-settled": .settled(through: 900_000),
        ])
        let hosts = [host(mini, name: "Mini", threads: threads, marks: settledMarks, activityByThreadID: [
            "stale-wait": .waiting, "undated-wait": .waiting, "settled-before": .waiting, "pinned-wait": .waiting,
            "undated-settled": .waiting,
        ], questions: ["stale-question": [36], "fresh-question": [999_000], "asked-after": [950_000]], waitingSince: [
            "stale-wait": 40, "settled-before": 850_000, "pinned-wait": 20,
        ])]
        var expanded = ConversationDrawerArrangement()
        expanded.isSettledFolded = false

        #expect(outline(hosts, arrangement: expanded) == [
            "[pinned]", "pinned-wait", "[chats]", "asked-after", "fresh-question", "undated-wait",
            "[settled]", "settled-before", "undated-settled", "stale-wait", "stale-question",
        ])
        let rows = sidebarRows(hosts: hosts, arrangement: expanded)
        #expect(rows.filter(\.needsInput).map(\.address.threadID) == ["asked-after", "fresh-question", "undated-wait"])
        #expect(rows.first { $0.address.threadID == "undated-wait" }?.canSettle == true)
    }

    @Test func settledRowsLeaveChatsForAFoldedShelfOrderedByRecency() throws {
        let threads = [
            try thread("recent", updatedAt: 900_000), try thread("old", updatedAt: 100),
            try thread("manual", updatedAt: 800_000), try thread("older", updatedAt: 50),
            try thread("pinned", updatedAt: 10), try thread("flagged", updatedAt: 20),
            try thread("running", updatedAt: 30), try thread("asking", updatedAt: 35),
            try thread("reopened", updatedAt: 600),
        ]
        var settledMarks = marks(schemaVersion: 2, pins: ["pinned": "Keep"],
                                 settlements: ["manual": .settled(through: 800_000), "reopened": .active(through: 700)])
        settledMarks.threads["flagged", default: ThreadMarks(revision: 1)].markedUnread = true
        let hosts = [host(mini, name: "Mini", threads: threads, marks: settledMarks,
                          activityByThreadID: ["running": .working], questions: ["asking": [asked]])]

        #expect(outline(hosts) == ["[pinned]", "pinned", "[chats]", "asking", "running", "flagged", "recent", "reopened", "[settled]"])
        #expect(items(hosts).last == .settledHeader(ConversationSectionSummary(
            fold: .folded, rowCount: 3, unreadCount: 0, liveActivity: nil)))

        var expanded = ConversationDrawerArrangement()
        expanded.isSettledFolded = false
        #expect(outline(hosts, arrangement: expanded).suffix(4) == ["[settled]", "manual", "old", "older"])
        let rows = Dictionary(uniqueKeysWithValues: sidebarRows(hosts: hosts, arrangement: expanded).map { ($0.address.threadID, $0) })
        #expect(rows["manual"]?.isSettled == true)
        #expect(rows["recent"]?.canSettle == true)
        #expect(rows["pinned"]?.canSettle == true)
        #expect(rows["running"]?.canSettle == false)
        #expect(rows["asking"]?.canSettle == true)
        #expect(rows["manual"]?.canSettle == false)

        let legacy = [host(mini, name: "Mini", threads: threads, marks: marks(pins: ["pinned": "Keep"]))]
        #expect(!outline(legacy).contains("[settled]"))
        #expect(sidebarRows(hosts: legacy).allSatisfy { $0.settlement == .unavailable })
    }

    @Test func projectsHoldOnlyUnsettledRowsAndDropProjectsWithNone() throws {
        let hosts = [host(mini, name: "Mini", threads: [
            try thread("a", updatedAt: 900_000, cwd: "/Users/developer/app"),
            try thread("b", updatedAt: 100, cwd: "/Users/developer/app"),
            try thread("c", updatedAt: 50, cwd: "/Users/developer/old"),
        ], marks: marks(schemaVersion: 2), remoteHomePath: "/Users/developer")]
        var projects = ConversationDrawerArrangement(mode: .projects)
        #expect(outline(hosts, arrangement: projects) == ["{~/app}", "a", "[settled]"])
        projects.isSettledFolded = false
        #expect(outline(hosts, arrangement: projects) == ["{~/app}", "a", "[settled]", "b", "c"])
    }

    @Test func theShelfShowsTenRowsRevealsMoreOnDemandAndKeepsTheOpenChat() throws {
        let threads = try (1...30).map { try thread("s\($0)", updatedAt: Int64($0) * 10) }
        let hosts = [host(mini, name: "Mini", threads: threads, marks: marks(schemaVersion: 2), activeThreadID: "s1")]
        let newestTen = (21...30).reversed().map { "s\($0)" }

        #expect(outline(hosts) == ["[settled]", "s1"])

        var expanded = ConversationDrawerArrangement()
        expanded.isSettledFolded = false
        #expect(outline(hosts, arrangement: expanded) == ["[settled]"] + newestTen + ["s1", "+19 settled"])

        expanded.settledRowLimit = ConversationDrawerArrangement.initialSettledRowLimit
            + ConversationDrawerArrangement.settledRowsRevealedPerStep
        #expect(outline(hosts, arrangement: expanded) == ["[settled]"] + (1...30).reversed().map { "s\($0)" })
    }

    @Test func searchCoversTheShelfAndUnreadOnlyLeavesItOut() throws {
        let threads = [try thread("fresh", updatedAt: 900_000, preview: "Release plan"),
                       try thread("old", updatedAt: 100, preview: "Release checklist"),
                       try thread("other", updatedAt: 200, preview: "Groceries")]
        let hosts = [host(mini, name: "Mini", threads: threads, marks: marks(schemaVersion: 2, readBaseline: 500))]

        var search = ConversationDrawerArrangement()
        search.query = "release"
        #expect(outline(hosts, arrangement: search) == ["fresh", "[settled]", "old"])
        #expect(items(hosts, arrangement: search).dropLast().last == .settledHeader(ConversationSectionSummary(
            fold: .searching, rowCount: 1, unreadCount: 0, liveActivity: nil)))

        var unreadOnly = ConversationDrawerArrangement(unreadOnly: true)
        unreadOnly.isSettledFolded = false
        #expect(outline(hosts, arrangement: unreadOnly) == ["fresh"])
        let open = [host(mini, name: "Mini", threads: threads, marks: marks(schemaVersion: 2, readBaseline: 500), activeThreadID: "old")]
        #expect(outline(open, arrangement: unreadOnly) == ["fresh", "[settled]", "old"])
    }

    @Test func capturedSettlementHoldsUntilASettlementChangeOnAnyDeviceOrReopen() throws {
        let threads = [try thread("a", updatedAt: 100), try thread("b", updatedAt: 900_000)]
        var expanded = ConversationDrawerArrangement()
        expanded.isSettledFolded = false
        let opened = [host(mini, name: "Mini", threads: threads, marks: marks(schemaVersion: 2))]
        let layout = ConversationSidebarProjection.layout(hosts: opened, at: openedAt)
        #expect(outline(opened, layout: layout, arrangement: expanded) == ["b", "[settled]", "a"])
        #expect(try settlement(of: "a", on: opened[0], captured: layout) == .settled)

        let active = [host(mini, name: "Mini", threads: [try thread("a", updatedAt: 950_000), threads[1]], marks: marks(schemaVersion: 2))]
        #expect(outline(active, layout: layout, arrangement: expanded) == ["b", "[settled]", "a"])
        #expect(try settlement(of: "a", on: active[0], captured: layout) == .settled)
        #expect(try settlement(of: "a", on: active[0]) == .unsettled)
        #expect(outline(active, layout: ConversationSidebarProjection.layout(hosts: active, at: openedAt),
                        arrangement: expanded) == ["a", "b"])

        let remote = marks(schemaVersion: 2, settlements: ["b": .settled(through: 900_000), "a": .active(through: 100)])
        let elsewhere = [host(mini, name: "Mini", threads: threads, marks: remote)]
        let arrived = ConversationSidebarProjection.admittingLayout(hosts: elsewhere, layout: layout)
        #expect(outline(elsewhere, layout: layout, arrangement: expanded) == ["a", "[settled]", "b"])
        #expect(outline(elsewhere, layout: arrived, arrangement: expanded) == ["a", "[settled]", "b"])
        #expect(ConversationSidebarProjection.admittingLayout(hosts: elsewhere, layout: arrived) == arrived)

        let edited = [host(mini, name: "Mini", threads: threads, marks: remote, settlementEdits: ["a": 1, "b": 1])]
        let admitted = ConversationSidebarProjection.admittingLayout(hosts: edited, layout: layout)
        #expect(outline(edited, layout: layout, arrangement: expanded) == ["a", "[settled]", "b"])
        #expect(outline(edited, layout: admitted, arrangement: expanded) == ["a", "[settled]", "b"])
        #expect(ConversationSidebarProjection.admittingLayout(hosts: edited, layout: admitted) == admitted)

        let pinnedSettled = marks(schemaVersion: 2, pins: ["a": "Kept"], settlements: ["a": .settled(through: 100)])
        let pinnedLayout = ConversationSidebarProjection.layout(
            hosts: [host(mini, name: "Mini", threads: threads, marks: pinnedSettled)], at: openedAt)
        let resettled = marks(schemaVersion: 2, settlements: ["a": .settled(through: 100)])
        for edits in [["a": 1], [:]] {
            let resettledAnywhere = [host(mini, name: "Mini", threads: threads, marks: resettled, settlementEdits: edits)]
            #expect(try settlement(of: "a", on: resettledAnywhere[0], captured: pinnedLayout) == .settled)
            #expect(outline(resettledAnywhere, layout: ConversationSidebarProjection.admittingLayout(
                hosts: resettledAnywhere, layout: pinnedLayout), arrangement: expanded) == ["b", "[settled]", "a"])
        }

        let legacy = host(mini, name: "Mini", threads: threads, marks: marks())
        #expect(try settlement(of: "a", on: legacy, captured: layout) == .unavailable)
        let openedBeforeMarks = ConversationSidebarProjection.layout(hosts: [legacy], at: openedAt)
        #expect(outline(opened, layout: ConversationSidebarProjection.admittingLayout(hosts: opened, layout: openedBeforeMarks),
                        arrangement: expanded) == ["b", "[settled]", "a"])
        var child = try thread("child", updatedAt: 100)
        child.agentRelation = .init(parentThreadId: "a", parentAccountId: nil, agentId: "launcher:run")
        #expect(try settlement(of: "child", on: host(mini, name: "Mini", threads: [child], marks: marks(schemaVersion: 2))) == .unavailable)
    }

    @Test func unreadOnlyShowsACapturedSettledRowThatTurnsUnreadInChats() throws {
        let threads = [try thread("a", updatedAt: 100), try thread("b", updatedAt: 900_000)]
        let opened = [host(mini, name: "Mini", threads: threads, marks: marks(schemaVersion: 2, readBaseline: 500_000))]
        let layout = ConversationSidebarProjection.layout(hosts: opened, at: openedAt)
        var flagged = marks(schemaVersion: 2, readBaseline: 500_000)
        flagged.threads["a", default: ThreadMarks(revision: 1)].markedUnread = true
        let unread = [host(mini, name: "Mini", threads: threads, marks: flagged)]

        #expect(outline(unread, layout: layout, arrangement: ConversationDrawerArrangement(unreadOnly: true)) == ["b", "a"])
        var expanded = ConversationDrawerArrangement()
        expanded.isSettledFolded = false
        #expect(outline(unread, layout: layout, arrangement: expanded) == ["b", "[settled]", "a"])
    }

    @Test func readingAManuallyUnreadSettledRowKeepsItInUnreadOnly() throws {
        let threads = [try thread("a", updatedAt: 100), try thread("b", updatedAt: 900_000)]
        let read = marks(schemaVersion: 2, readBaseline: 500_000, settlements: ["a": .settled(through: 100)])
        var flagged = read
        flagged.threads["a"]?.markedUnread = true
        let layout = ConversationSidebarProjection.layout(hosts: [host(mini, name: "Mini", threads: threads, marks: flagged)], at: openedAt)
        let afterRead = [host(mini, name: "Mini", threads: threads, marks: read)]
        #expect(outline(afterRead, layout: ConversationSidebarProjection.admittingLayout(hosts: afterRead, layout: layout),
                        arrangement: ConversationDrawerArrangement(unreadOnly: true)) == ["b", "a"])
    }

    @Test func unreadOnlyKeepsUnreadRowsTheirCapturedRankAndTheOpenChat() throws {
        let threads = [try thread("unread", updatedAt: 500), try thread("read", updatedAt: 300), try thread("open", updatedAt: 200)]
        let unread = [host(mini, name: "Mini", threads: threads, marks: marks(readBaseline: 400), activeThreadID: "open")]
        let filter = ConversationDrawerArrangement(unreadOnly: true)
        let layout = ConversationSidebarProjection.layout(hosts: unread, at: openedAt)
        #expect(outline(unread, layout: layout, arrangement: filter) == ["unread", "open"])

        let seen = [host(mini, name: "Mini", threads: threads, marks: marks(readBaseline: 400, seen: ["unread": 500]),
                         activeThreadID: "open")]
        #expect(outline(seen, layout: layout, arrangement: filter) == ["unread", "open"])
        #expect(outline(seen, layout: ConversationSidebarProjection.layout(hosts: seen, at: openedAt), arrangement: filter) == ["open"])
    }

    @Test func projectsMergeOneRemoteAcrossHostsAndOrderByLatestActivity() throws {
        let hosts = [
            host(mini, name: "Mini", threads: [
                try thread("mini-repo", updatedAt: 300, cwd: "/Users/developer/RemoteCoder"),
                try thread("notes", updatedAt: 500, cwd: "/Users/developer/notes"),
                try thread("loose", updatedAt: 100, cwd: "/Users/developer/scratch"),
            ], remoteHomePath: "/Users/developer", projects: [
                "/Users/developer/RemoteCoder": identity("/Users/developer/RemoteCoder", .remote, key: "github.com/e/RemoteCoder", name: "RemoteCoder"),
                "/Users/developer/notes": identity("/Users/developer/notes", .directory, key: "/Users/developer/notes", name: "notes"),
            ]),
            host(book, name: "Book", threads: [
                try thread("book-worktree", updatedAt: 400, cwd: "/Users/developer/wt/drawer"),
            ], remoteHomePath: "/Users/developer", projects: [
                "/Users/developer/wt/drawer": identity("/Users/developer/wt/drawer", .remote, key: "github.com/e/RemoteCoder", name: "RemoteCoder"),
            ]),
        ]

        let projects = ConversationDrawerArrangement(mode: .projects)
        #expect(outline(hosts, arrangement: projects) == [
            "{~/notes · Mini}", "notes", "{RemoteCoder}", "book-worktree", "mini-repo", "{~/scratch · Mini}", "loose",
        ])
    }

    @Test func foldedProjectsKeepASummaryAndLongOnesRevealTheRestOnDemand() throws {
        let threads = try (1...7).map { try thread("t\($0)", updatedAt: Int64($0) * 100, cwd: "/Users/developer/app") }
        let hosts = [host(mini, name: "Mini", threads: threads, marks: marks(readBaseline: 650),
                          remoteHomePath: "/Users/developer", activityByThreadID: ["t1": .working])]
        let key = "\(mini.uuidString)|directory|/Users/developer/app"

        let limited = ConversationDrawerArrangement(mode: .projects, projectRowLimit: 5)
        #expect(outline(hosts, arrangement: limited) == ["{~/app}", "t1", "t7", "t6", "t5", "t4", "+2"])

        var revealed = limited
        revealed.revealedProjects = [key]
        #expect(outline(hosts, arrangement: revealed).count == 8)

        var folded = limited
        folded.foldedProjects = [key]
        let items = ConversationSidebarProjection.items(hosts: hosts, selectedHostID: mini, layout: live,
                                                        arrangement: folded, condensedPaths: CondensedPathCache())
        #expect(items == [.project(ConversationProjectHeader(key: key, title: "~/app", hostName: nil, summary: ConversationSectionSummary(
            fold: .folded, rowCount: 7, unreadCount: 1, liveActivity: .working)))])
    }

    @Test func foldedPinnedChatsKeepASummaryUntilASearchMatchesThem() throws {
        let threads = [try thread("a", updatedAt: 100), try thread("b", updatedAt: 200), try thread("c", updatedAt: 300)]
        let hosts = [host(mini, name: "Mini", threads: threads, marks: marks(pins: ["a": "Alpha", "b": "Beta"], readBaseline: 150),
                          activityByThreadID: ["a": .working])]
        var folded = ConversationDrawerArrangement()
        folded.isPinnedFolded = true

        #expect(items(hosts, arrangement: folded).first == .pinnedHeader(ConversationSectionSummary(
            fold: .folded, rowCount: 2, unreadCount: 1, liveActivity: .working)))
        #expect(outline(hosts, arrangement: folded) == ["[pinned]", "[chats]", "c"])

        folded.query = "beta"
        #expect(outline(hosts, arrangement: folded) == ["[pinned]", "b"])
        #expect(items(hosts, arrangement: folded).first == .pinnedHeader(ConversationSectionSummary(
            fold: .searching, rowCount: 1, unreadCount: 1, liveActivity: nil)))
    }

    @Test func foldedSummariesShowNeedsInputBeforeWorking() throws {
        let threads = [try thread("working", updatedAt: 100), try thread("asking", updatedAt: 200),
                       try thread("waiting", updatedAt: 300)]
        func pinnedHeader(_ activity: [String: CodexGatewayDaemon.ActivityState],
                          questions: [String: [Int64]] = [:]) -> ConversationSidebarItem? {
            let hosts = [host(mini, name: "Mini", threads: threads,
                              marks: marks(pins: ["working": "A", "asking": "B", "waiting": "C"]),
                              activityByThreadID: activity, questions: questions)]
            var folded = ConversationDrawerArrangement()
            folded.isPinnedFolded = true
            return items(hosts, arrangement: folded).first
        }
        func folded(_ liveActivity: CodexGatewayDaemon.ActivityState?) -> ConversationSidebarItem {
            .pinnedHeader(ConversationSectionSummary(fold: .folded, rowCount: 3, unreadCount: 0, liveActivity: liveActivity))
        }

        #expect(pinnedHeader(["working": .working, "waiting": .waiting]) == folded(.waiting))
        #expect(pinnedHeader(["working": .working], questions: ["asking": [asked]]) == folded(.waiting))
        #expect(pinnedHeader(["working": .working]) == folded(.working))
        #expect(pinnedHeader(["working": .unknown]) == folded(.unknown))
        #expect(pinnedHeader(["working": .idle]) == folded(nil))
    }

    @Test func aHeldSnapshotKeepsTheDisplayedOrderAndFoldsWithFreshContent() throws {
        let threads = [try thread("a", updatedAt: 100), try thread("b", updatedAt: 200), try thread("c", updatedAt: 300)]
        let pins = ["a": "Alpha", "b": "Beta"]
        let shown = ConversationSidebarSnapshot(
            drafts: [], hiddenDraftCount: 0, items: items([host(mini, name: "Mini", threads: threads, marks: marks(pins: pins))]), hostStates: [])
        var folded = ConversationDrawerArrangement()
        folded.isPinnedFolded = true
        let arriving = ConversationSidebarSnapshot(
            drafts: [], hiddenDraftCount: 0, items: items([host(mini, name: "Mini", threads: threads, marks: marks(pins: pins, readBaseline: 150))],
                         arrangement: folded),
            hostStates: [])

        let held = arriving.heldInLayout(of: shown)

        #expect(held.items.map(\.id) == shown.items.map(\.id))
        #expect(held.items.first == .pinnedHeader(ConversationSectionSummary(
            fold: .expanded, rowCount: 2, unreadCount: 1, liveActivity: nil)))
        let unread = held.items.compactMap { item in if case let .row(row) = item, row.isUnread { row.address.threadID } else { nil } }
        #expect(unread == ["c"])
    }

    @Test func pinnedRowsStayAboveProjects() throws {
        let hosts = [host(mini, name: "Mini", threads: [try thread("a", updatedAt: 100), try thread("b", updatedAt: 200)],
                          marks: marks(pins: ["a": "Keep"]), remoteHomePath: "/Users/developer")]
        #expect(outline(hosts, arrangement: ConversationDrawerArrangement(mode: .projects)) == ["[pinned]", "a", "{~/repo}", "b"])
    }

    @Test func searchMatchesTitleFolderAndVisibleHostIgnoringFoldsAndLimits() throws {
        let hosts = [
            host(mini, name: "Mini", threads: [
                try thread("release", updatedAt: 400, preview: "Release checklist", cwd: "/Users/developer/RemoteCoder"),
                try thread("api", updatedAt: 300, preview: "API cleanup", cwd: "/Users/developer/work/service"),
            ], remoteHomePath: "/Users/developer"),
            host(book, name: "MacBook", threads: [
                try thread("cafe", updatedAt: 200, preview: "Café menu", cwd: "/Users/developer/site"),
                try thread("notes", updatedAt: 100, preview: "Old API notes", cwd: "/Users/developer/RemoteCoder"),
            ], remoteHomePath: "/Users/developer"),
        ]
        func matches(_ query: String, _ arrangement: ConversationDrawerArrangement = .init()) -> [String] {
            var arrangement = arrangement
            arrangement.query = query
            return sidebarRows(hosts: hosts, arrangement: arrangement).map(\.address.threadID)
        }

        #expect(matches("  ") == ["release", "api", "cafe", "notes"])
        #expect(matches("CAFE") == ["cafe"])
        #expect(matches("service") == ["api"])
        #expect(matches("macbook") == ["cafe", "notes"])
        #expect(matches("mini api") == ["api"])
        #expect(matches("api remotecoder") == ["notes"])
        #expect(matches("mini site").isEmpty)

        let folded = ConversationDrawerArrangement(
            mode: .projects, foldedProjects: ["\(mini.uuidString)|directory|/Users/developer/work/service"], projectRowLimit: 0)
        #expect(matches("api", folded) == ["api", "notes"])

        let single = [host(mini, name: "Mini", threads: [try thread("only", updatedAt: 1, preview: "Draft")])]
        var named = ConversationDrawerArrangement()
        named.query = "mini"
        #expect(sidebarRows(hosts: single, arrangement: named).isEmpty)
    }

    @Test func aFirstTurnUsesCreationTimeRegardlessOfToolActivity() throws {
        let data = Data("""
        {"id":"first","preview":"First turn","modelProvider":"test","createdAt":150,
         "updatedAt":10000,"cwd":"/repo","cliVersion":"test","source":"appServer"}
        """.utf8)
        let first = ConversationHeader(try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: data))
        let rows = sidebarRows(hosts: [host(mini, name: "Mini", threads: [first, try thread("finished", updatedAt: 200)])])
        #expect(rows.map(\.address.threadID) == ["finished", "first"])
        #expect(first.sidebarTimestamp == 150)
    }

    @Test func aStartedTurnCountsAsLatestActivity() throws {
        let started = try ThreadFixture.basic("started", updatedAt: 100, fields: ["lastTurnCompletedAt": 100, "recencyAt": 500])
        let rows = sidebarRows(hosts: [host(mini, name: "Mini", threads: [try thread("finished", updatedAt: 300), started])])
        #expect(rows.map(\.address.threadID) == ["started", "finished"])
        #expect(rows.first?.sidebarDate == Date(timeIntervalSince1970: 500))
    }

    @Test func sharedPathCacheKeepsEachHostsHome() throws {
        let condensedPaths = CondensedPathCache()
        let hosts = [
            host(mini, name: "Mac Mini", threads: [try thread("a", updatedAt: 1)], remoteHomePath: "/Users/developer"),
            host(book, name: "MacBook", threads: [try thread("b", updatedAt: 2)], remoteHomePath: "/Users"),
        ]
        for _ in 0..<2 {
            let rows = sidebarRows(hosts: hosts, condensedPaths: condensedPaths)
            #expect(rows.map(\.workingDirectory) == ["~/developer/repo", "~/repo"])
        }
    }

    // MARK: - Fixtures

    private func items(
        _ hosts: [ConversationSidebarHostInput],
        selectedHostID: UUID? = nil,
        layout: ConversationDrawerLayout? = nil,
        arrangement: ConversationDrawerArrangement = .init(),
        condensedPaths: CondensedPathCache = CondensedPathCache()
    ) -> [ConversationSidebarItem] {
        ConversationSidebarProjection.items(hosts: hosts, selectedHostID: selectedHostID ?? mini, layout: layout ?? live,
                                            arrangement: arrangement, condensedPaths: condensedPaths)
    }

    private func sidebarRows(
        hosts: [ConversationSidebarHostInput],
        selectedHostID: UUID? = nil,
        layout: ConversationDrawerLayout? = nil,
        arrangement: ConversationDrawerArrangement = .init(),
        condensedPaths: CondensedPathCache = CondensedPathCache()
    ) -> [ConversationSidebarRow] {
        items(hosts, selectedHostID: selectedHostID, layout: layout, arrangement: arrangement, condensedPaths: condensedPaths)
            .compactMap { item in if case let .row(row) = item { row } else { nil } }
    }

    private func outline(
        _ hosts: [ConversationSidebarHostInput],
        layout: ConversationDrawerLayout? = nil,
        arrangement: ConversationDrawerArrangement = .init()
    ) -> [String] {
        items(hosts, layout: layout, arrangement: arrangement).map { item in
            switch item {
            case .pinnedHeader: "[pinned]"
            case .chatsHeader: "[chats]"
            case .automationsHeader: "[automations]"
            case let .project(header): "{\(header.title)\(header.hostName.map { " · \($0)" } ?? "")}"
            case let .more(_, hidden): "+\(hidden)"
            case .settledHeader: "[settled]"
            case let .moreSettled(hidden): "+\(hidden) settled"
            case let .row(row): row.address.threadID
            }
        }
    }

    private func settlement(of id: String, on host: ConversationSidebarHostInput,
                            captured layout: ConversationDrawerLayout? = nil) throws -> ConversationSidebarRow.Settlement {
        let thread = try #require(host.threads.first { $0.id == id })
        return ConversationSidebarProjection.settlement(
            of: thread, marks: host.marks, activity: host.activityByThreadID[id],
            questionAskTimes: host.questionAskTimesByThreadID[id] ?? [], waitingSince: host.waitingSinceByThreadID[id],
            settlementEdit: host.settlementEdits[id] ?? 0,
            captured: layout?.ranks(on: host.target)[id], at: layout?.capturedAt ?? Int64(openedAt.timeIntervalSince1970))
    }

    private func marks(
        schemaVersion: Int = 1,
        pins: [String: String] = [:],
        readBaseline: Int64 = .max,
        seen: [String: Int64] = [:],
        purposes: [String: ConversationPurpose] = [:],
        settlements: [String: ConversationSettlement] = [:]
    ) -> ConversationMarks {
        var threads: [String: ThreadMarks] = [:]
        for (id, name) in pins { threads[id, default: ThreadMarks(revision: 1)].pinName = name }
        for (id, through) in seen { threads[id, default: ThreadMarks(revision: 1)].seenThrough = through }
        for (id, purpose) in purposes { threads[id, default: ThreadMarks(revision: 1)].purpose = purpose }
        for (id, settlement) in settlements { threads[id, default: ThreadMarks(revision: 1)].settlement = settlement }
        return ConversationMarks(schemaVersion: schemaVersion, revision: 1, readBaseline: readBaseline, threads: threads)
    }

    private func identity(_ cwd: String, _ kind: ProjectIdentity.Kind, key: String, name: String) -> ProjectIdentity {
        ProjectIdentity(cwd: cwd, kind: kind, key: key, name: name, root: cwd)
    }

    private func host(
        _ hostID: UUID,
        name: String,
        threads: [ConversationHeader],
        marks: ConversationMarks? = nil,
        remoteHomePath: String? = nil,
        activityByThreadID: [String: CodexGatewayDaemon.ActivityState] = [:],
        questions: [String: [Int64]] = [:],
        activeThreadID: String? = nil,
        loadingThreadID: String? = nil,
        isLoading: Bool = false,
        errorMessage: String? = nil,
        isGatewayRestarting: Bool = false,
        projects: [String: ProjectIdentity] = [:],
        settlementEdits: [String: Int] = [:],
        waitingSince: [String: Int64] = [:]
    ) -> ConversationSidebarHostInput {
        ConversationSidebarHostInput(
            hostID: hostID,
            hostName: name,
            threads: threads,
            marks: marks ?? self.marks(),
            remoteHomePath: remoteHomePath,
            activityByThreadID: activityByThreadID,
            activeThreadID: activeThreadID,
            loadingThreadID: loadingThreadID,
            isLoading: isLoading,
            errorMessage: errorMessage,
            isGatewayRestarting: isGatewayRestarting,
            questionAskTimesByThreadID: questions,
            waitingSinceByThreadID: waitingSince,
            projects: projects,
            settlementEdits: settlementEdits
        )
    }

    private func thread(
        _ id: String,
        updatedAt: Int64,
        preview: String = "Test",
        cwd: String = "/Users/developer/repo"
    ) throws -> ConversationHeader {
        try ThreadFixture.basic(id, updatedAt: updatedAt, preview: preview,
            fields: ["lastTurnCompletedAt": updatedAt, "cwd": cwd])
    }
}
