import Foundation
import Testing
@testable import RemoteCoderCore

struct QuickEntryRecentsTests {
    private let host = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test func conversationsNeedingInputComeFirstThenTheMostRecent() {
        let items: [ConversationSidebarItem] = [
            .pinnedHeader(ConversationSectionSummary(fold: .expanded, rowCount: 1, unreadCount: 0, liveActivity: nil)),
            .row(row("pinned-old", at: 10)),
            .more(projectKey: "remote|example", hiddenCount: 2),
            .row(row("newest", at: 400)),
            .row(row("question", at: 100, questionCount: 2, needsInput: true)),
            .row(row("waiting", at: 50, activity: .waiting, needsInput: true)),
            .row(row("working", at: 300, activity: .working)),
            .row(row("answered", at: 200, questionCount: 0)),
        ]

        let recents = QuickEntryRecents.rows(from: items, limit: 10).map(\.address.threadID)

        #expect(recents == ["question", "waiting", "newest", "working", "answered", "pinned-old"])
    }

    @Test func theListStopsAtItsLimitAndBreaksTiesByIdentity() {
        let items: [ConversationSidebarItem] = [
            .row(row("b", at: 100)), .row(row("a", at: 100)), .row(row("c", at: 90)),
        ]

        #expect(QuickEntryRecents.rows(from: items, limit: 2).map(\.address.threadID) == ["a", "b"])
    }

    @Test func automationRunsDoNotDisplaceRecentsUnlessExplicitlyPinned() {
        let items: [ConversationSidebarItem] = [
            .row(row("automatic", at: 300, isAutomation: true)),
            .row(row("pinned-automatic", at: 200, isPinned: true, isAutomation: true)),
            .row(row("conversation", at: 100)),
        ]

        #expect(QuickEntryRecents.rows(from: items, limit: 2).map(\.address.threadID) == ["pinned-automatic", "conversation"])
    }

    private func row(_ threadID: String, at seconds: TimeInterval, activity: CodexGatewayDaemon.ActivityState? = nil,
                     questionCount: Int? = nil, needsInput: Bool = false, isPinned: Bool = false, isAutomation: Bool = false) -> ConversationSidebarRow {
        let address = ConversationAddress(hostID: host, threadID: threadID)
        return ConversationSidebarRow(
            id: address.id, address: address, hostName: "Mini", showsHostLabel: false, title: threadID,
            preview: "", sidebarDate: Date(timeIntervalSince1970: seconds), dateLabel: "", ageLabel: "", workingDirectory: "~/repo",
            isPinned: isPinned, isUnread: false, isSelected: false, isLoading: false, activity: activity,
            isAutomation: isAutomation, questionCount: questionCount, needsInput: needsInput)
    }
}
