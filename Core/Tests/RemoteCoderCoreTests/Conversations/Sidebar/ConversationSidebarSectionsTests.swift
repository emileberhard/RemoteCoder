import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationSidebarSectionsTests {
    private let mini = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test func pinnedAndChatsHeadersEachOpenTheirOwnSection() {
        let sections = ConversationSidebarSections.sections(of: [
            .pinnedHeader(summary(isFolded: false)),
            .row(row("pinned", isPinned: true)),
            .chatsHeader,
            .row(row("recent")),
            .row(row("older")),
        ])

        #expect(sections.map(\.kind) == [.pinned(summary(isFolded: false)), .chats])
        #expect(sections.map { $0.rows.map(\.address.threadID) } == [["pinned"], ["recent", "older"]])
    }

    @Test func foldedPinnedKeepsItsEmptySection() {
        let sections = ConversationSidebarSections.sections(of: [
            .pinnedHeader(summary(isFolded: true)),
            .chatsHeader,
            .row(row("recent")),
        ])

        #expect(sections.map(\.kind) == [.pinned(summary(isFolded: true)), .chats])
        #expect(sections.map { $0.rows.map(\.address.threadID) } == [[], ["recent"]])
    }

    @Test func rowsWithoutAHeaderStayUnsectioned() {
        let sections = ConversationSidebarSections.sections(of: [.row(row("recent"))])
        #expect(sections.map(\.kind) == [.unsectioned])
    }

    @Test func projectsKeepTheirSectionWhenFoldedAndIgnoreMoreItems() {
        let folded = project("remote|github.com/example/site", isFolded: true)
        let open = project("remote|github.com/example/remotecoder", isFolded: false)
        let sections = ConversationSidebarSections.sections(of: [
            .pinnedHeader(summary(isFolded: false)),
            .row(row("pinned", isPinned: true)),
            .project(folded),
            .project(open),
            .row(row("first")),
            .more(projectKey: open.key, hiddenCount: 3),
        ])

        #expect(sections.map(\.kind) == [.pinned(summary(isFolded: false)), .project(folded), .project(open)])
        #expect(sections.map { $0.rows.map(\.address.threadID) } == [["pinned"], [], ["first"]])
        #expect(Set(sections.map(\.id)).count == sections.count)
    }

    @Test func theSettledShelfClosesThePrecedingRowsAndCarriesItsHiddenCount() {
        let sections = ConversationSidebarSections.sections(of: [
            .row(row("recent")),
            .settledHeader(summary(isFolded: false)),
            .row(row("settled")),
            .moreSettled(hiddenCount: 4),
        ])

        #expect(sections.map(\.kind) == [.unsectioned, .settled(summary(isFolded: false), hiddenRowCount: 4)])
        #expect(sections.map { $0.rows.map(\.address.threadID) } == [["recent"], ["settled"]])

        let folded = ConversationSidebarSections.sections(of: [.row(row("recent")), .settledHeader(summary(isFolded: true))])
        #expect(folded.map(\.kind) == [.unsectioned, .settled(summary(isFolded: true), hiddenRowCount: 0)])
        #expect(folded.last?.rows.isEmpty == true)
        #expect(Set(sections.map(\.id)).count == sections.count)
    }

    @Test func noItemsMeansNoSections() {
        #expect(ConversationSidebarSections.sections(of: []).isEmpty)
    }

    private func project(_ key: String, isFolded: Bool) -> ConversationProjectHeader {
        ConversationProjectHeader(key: key, title: key, hostName: nil, summary: summary(isFolded: isFolded))
    }

    private func summary(isFolded: Bool) -> ConversationSectionSummary {
        ConversationSectionSummary(fold: isFolded ? .folded : .expanded, rowCount: 1, unreadCount: 0, liveActivity: nil)
    }

    private func row(_ threadID: String, isPinned: Bool = false) -> ConversationSidebarRow {
        let address = ConversationAddress(hostID: mini, threadID: threadID)
        return ConversationSidebarRow(
            id: address.id,
            address: address,
            hostName: "Mini",
            showsHostLabel: false,
            title: threadID,
            preview: threadID,
            sidebarDate: Date(timeIntervalSince1970: 1_000_000),
            dateLabel: "", ageLabel: "",
            workingDirectory: "~/repo",
            isPinned: isPinned,
            isUnread: false,
            isSelected: false,
            isLoading: false,
            activity: nil
        )
    }
}
