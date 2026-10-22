import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationSidebarNavigationTests {
    private let mini = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let book = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func rowsKeepSidebarOrderWithoutSectionHeaders() {
        let summary = ConversationSectionSummary(fold: .expanded, rowCount: 2, unreadCount: 0, liveActivity: nil)
        let project = ConversationProjectHeader(key: "remote|example", title: "example", hostName: nil, summary: summary)
        let items: [ConversationSidebarItem] = [
            .pinnedHeader(summary), .row(row("a")), .project(project), .row(row("b")), .row(row("c")),
        ]
        #expect(ConversationSidebarNavigation.rows(of: items).map(\.address.threadID) == ["a", "b", "c"])
    }

    @Test func neighborsFollowSidebarOrderAndStopAtTheEnds() {
        let rows = [row("a"), row("b"), row("c")]
        #expect(ConversationSidebarNavigation.neighbor(.next, of: address("a"), in: rows) == address("b"))
        #expect(ConversationSidebarNavigation.neighbor(.previous, of: address("b"), in: rows) == address("a"))
        #expect(ConversationSidebarNavigation.neighbor(.previous, of: address("a"), in: rows) == nil)
        #expect(ConversationSidebarNavigation.neighbor(.next, of: address("c"), in: rows) == nil)
    }

    @Test func aConversationOutsideTheListStartsFromTheTopOrTheBottom() {
        let rows = [row("a"), row("b"), row("c")]
        let sameThreadOnAnotherHost = ConversationAddress(hostID: book, threadID: "b")
        #expect(ConversationSidebarNavigation.neighbor(.next, of: nil, in: rows) == address("a"))
        #expect(ConversationSidebarNavigation.neighbor(.previous, of: nil, in: rows) == address("c"))
        #expect(ConversationSidebarNavigation.neighbor(.next, of: sameThreadOnAnotherHost, in: rows) == address("a"))
    }

    @Test func positionsCountFromOne() {
        let rows = [row("a"), row("b"), row("c")]
        #expect(ConversationSidebarNavigation.address(atPosition: 1, in: rows) == address("a"))
        #expect(ConversationSidebarNavigation.address(atPosition: 3, in: rows) == address("c"))
        #expect(ConversationSidebarNavigation.address(atPosition: 0, in: rows) == nil)
        #expect(ConversationSidebarNavigation.address(atPosition: 4, in: rows) == nil)
    }

    @Test func attentionPrefersTheNextPendingQuestionAndWrapsAround() {
        let rows = [
            row("a", isUnread: true), row("b"), row("c", questionCount: 1),
            row("d", isUnread: true), row("e", questionCount: 2),
        ]
        #expect(ConversationSidebarNavigation.nextNeedingAttention(after: address("b"), in: rows) == address("c"))
        #expect(ConversationSidebarNavigation.nextNeedingAttention(after: address("c"), in: rows) == address("e"))
        #expect(ConversationSidebarNavigation.nextNeedingAttention(after: address("e"), in: rows) == address("c"))
        #expect(ConversationSidebarNavigation.nextNeedingAttention(after: nil, in: rows) == address("c"))
    }

    @Test func attentionFallsBackToUnreadCompletions() {
        let rows = [row("a", isUnread: true), row("b"), row("c", questionCount: 0), row("d", isUnread: true)]
        #expect(ConversationSidebarNavigation.nextNeedingAttention(after: address("d"), in: rows) == address("a"))
        #expect(ConversationSidebarNavigation.nextNeedingAttention(after: address("a"), in: rows) == address("d"))
    }

    @Test func theCurrentConversationAloneNeedsNoNavigation() {
        let rows = [row("a"), row("b", isUnread: true, questionCount: 1), row("c")]
        #expect(ConversationSidebarNavigation.nextNeedingAttention(after: address("b"), in: rows) == nil)
    }

    private func address(_ threadID: String) -> ConversationAddress {
        ConversationAddress(hostID: mini, threadID: threadID)
    }

    private func row(_ threadID: String, isUnread: Bool = false, questionCount: Int? = nil) -> ConversationSidebarRow {
        let address = address(threadID)
        return ConversationSidebarRow(
            id: address.id, address: address, hostName: "Mini", showsHostLabel: false, title: threadID,
            preview: threadID, sidebarDate: Date(timeIntervalSince1970: 0), dateLabel: "", ageLabel: "", workingDirectory: "~",
            isPinned: false, isUnread: isUnread, isSelected: false, isLoading: false, activity: nil,
            questionCount: questionCount)
    }
}
