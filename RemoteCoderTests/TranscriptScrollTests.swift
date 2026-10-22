import CoreGraphics
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import RemoteCoder

struct TranscriptScrollTests {
    @Test @MainActor func growthAnimationSamplesVisibilityWithoutSubscribingToScrollChanges() {
        let visibility = TranscriptVisibility()
        let row = TranscriptRowVisibility(rowID: "reply", visibility: visibility)
        let steadyChanged = Mutex(false)
        let visibleChanged = Mutex(false)
        withObservationTracking { _ = row.isSteadilyVisible } onChange: { steadyChanged.withLock { $0 = true } }
        withObservationTracking { _ = row.isVisible } onChange: { visibleChanged.withLock { $0 = true } }
        visibility.setVisibleRowIDs(["reply"])
        #expect(row.isSteadilyVisible)
        #expect(!steadyChanged.withLock { $0 })
        #expect(visibleChanged.withLock { $0 })
        visibility.setVisibleRowIDs([])
        #expect(!row.isSteadilyVisible)
        #expect(!steadyChanged.withLock { $0 })
    }

    @Test(arguments: [false, true])
    func rowsWithoutUserTurnsCannotBypassMountLimits(activityOnly: Bool) {
        let rows = (0..<200).map { index in
            activityOnly ? TranscriptRow.activity(JobTimelineEvent(id: "event-\(index)", sequence: index,
                kind: .status, title: "Working", subtitle: nil, timestamp: nil, details: []), isLast: index == 199)
                : message(.codex, 10)
        }
        #expect(TranscriptRow.sliceStart(before: rows.endIndex, in: rows) == 184)
        #expect(TranscriptRow.batchStart(before: rows.endIndex, in: rows) == 120)
        #expect(TranscriptRow.backlogIsShort(before: 79, in: rows))
        #expect(!TranscriptRow.backlogIsShort(before: 80, in: rows))
        #expect(TranscriptRow.runwayIsShort(above: [rows[39].id], in: rows) == true)
        #expect(TranscriptRow.runwayIsShort(above: [rows[40].id], in: rows) == false)
        #expect(!TranscriptRow.exceedsFollowingBudget(rows[..<119]))
        #expect(TranscriptRow.exceedsFollowingBudget(rows[..<120]))
        let visible = 160
        let start = visible - 39
        let revealedStart = TranscriptRow.batchStart(before: start, in: rows)
        #expect(!TranscriptRow.exceedsFollowingBudget(rows[revealedStart..<visible]))
    }

    @Test func aShortLatestTurnGetsOnlyTheMissingViewportHeight() {
        #expect(TranscriptLayout.tailPadding(heights: [100, 500, 60, 40, 20],
            latestTurnIndex: 2, minimumTurnHeight: 700) == 588)
    }

    @Test func aLongTurnAndHistoryWithoutAUserNeedNoExtraSpace() {
        #expect(TranscriptLayout.tailPadding(heights: [60, 900, 20],
            latestTurnIndex: 0, minimumTurnHeight: 700) == 0)
        #expect(TranscriptLayout.tailPadding(heights: [100, 20],
            latestTurnIndex: nil, minimumTurnHeight: 700) == 0)
        #expect(TranscriptLayout.tailPadding(heights: [],
            latestTurnIndex: nil, minimumTurnHeight: 700) == 0)
    }

    private func message(_ role: ChatMessage.Role, _ length: Int) -> TranscriptRow {
        .content(.message(ChatMessage(role: role, text: String(repeating: "a", count: length))))
    }

    private var gap: TranscriptRow {
        .content(.historyEdge(HistoryEdge(kind: .older, cursor: "earlier")))
    }

    @Test func anOpeningTranscriptMountsNoMoreThanItsLatestTurn() {
        let rows = [message(.user, 10), message(.codex, 10), message(.user, 10), message(.codex, 10)]
        #expect(TranscriptRow.openingStart(of: rows) == 2)
        #expect(TranscriptRow.openingStart(of: []) == 0)
    }

    @Test func aLongLatestTurnOpensAtAMessageWithinTheBudget() {
        let rows = [message(.user, 10), message(.codex, 3_000), message(.codex, 3_000), message(.codex, 3_000)]
        #expect(TranscriptRow.openingStart(of: rows) == 2)
        let agentInitiated = [message(.codex, 3_000), gap, message(.codex, 3_000), message(.codex, 3_000)]
        #expect(TranscriptRow.openingStart(of: agentInitiated) == 2)
    }

    private func turns(_ count: Int) -> [TranscriptRow] {
        (0..<count).flatMap { _ in [message(.user, 10), message(.codex, 10)] }
    }

    @Test func aBatchMountsTwentyFiveTurnsUnlessTheirTextReachesTheCeiling() {
        let rows = turns(30)
        #expect(TranscriptRow.batchStart(before: 60, in: rows) == 10)
        #expect(TranscriptRow.batchStart(before: 10, in: rows) == 0)
        let long = [message(.user, 10), message(.codex, 100_000), message(.codex, 100_000), message(.user, 10), message(.codex, 10)]
        #expect(TranscriptRow.batchStart(before: 3, in: long) == 1)
    }

    @Test func aSliceMountsTwoTurnsOrOneOversizedMessage() {
        #expect(TranscriptRow.sliceStart(before: 60, in: turns(30)) == 56)
        let long = [message(.user, 10), message(.codex, 100_000), message(.codex, 100_000), message(.user, 10), message(.codex, 10)]
        #expect(TranscriptRow.sliceStart(before: 3, in: long) == 2)
        #expect(TranscriptRow.sliceStart(before: 3, in: [message(.user, 10), message(.codex, 5_000), message(.codex, 5_000)]) == 1)
    }

    @Test func onlyHalfABatchBeyondTheFollowingWindowTrimsIt() {
        #expect(!TranscriptRow.exceedsFollowingBudget(turns(36)))
        #expect(TranscriptRow.exceedsFollowingBudget(turns(37)))
        #expect(!TranscriptRow.exceedsFollowingBudget([message(.user, 10), message(.codex, 200_000)]))
        #expect(TranscriptRow.exceedsFollowingBudget([message(.user, 10), message(.codex, 120_000), message(.codex, 120_000)]))
    }

    @Test func aFollowerKeepsTheLatestBatchThatATrimDoesNotImmediatelyExceed() {
        let rows = turns(40)
        let start = TranscriptRow.followingStart(of: rows)
        #expect(start == 30)
        #expect(start < TranscriptRow.openingStart(of: rows))
        #expect(!TranscriptRow.exceedsFollowingBudget(rows[start...]))
    }

    @Test func aBacklogIsShortUntilItFillsABatch() {
        let rows = [gap] + turns(25)
        #expect(TranscriptRow.backlogIsShort(before: 49, in: rows))
        #expect(!TranscriptRow.backlogIsShort(before: rows.endIndex, in: rows))
        #expect(!TranscriptRow.backlogIsShort(before: 2, in: [gap, message(.codex, 160_000)]))
    }

    @Test func theRunwayIsShortUntilHalfABatchOfTurnsOrTextLiesAboveTheReader() {
        let rows = [gap] + turns(13)
        #expect(TranscriptRow.runwayIsShort(above: [rows[23].id, rows[24].id], in: rows) == true)
        #expect(TranscriptRow.runwayIsShort(above: [rows[25].id], in: rows) == false)
        let fewTurns = [message(.user, 10), message(.codex, 80_000), message(.codex, 10)]
        #expect(TranscriptRow.runwayIsShort(above: [fewTurns[1].id], in: fewTurns) == true)
        #expect(TranscriptRow.runwayIsShort(above: [fewTurns[2].id], in: fewTurns) == false)
        #expect(TranscriptRow.runwayIsShort(above: [], in: rows) == nil)
    }

    @Test func completingATopScrollCannotSilentlyReenableFollowing() {
        var state = TranscriptFollowState()
        state.revealRow()
        let followsAfterAnimation = state.endUserScroll(atBottom: true, of: [])
        #expect(!followsAfterAnimation)
        #expect(!state.isFollowingLatest)
    }

    @Test func onlyAnExplicitJumpOrUserScrollToTheEndFollows() {
        var state = TranscriptFollowState()
        state.beginUserScroll()
        let followsAwayFromBottom = state.endUserScroll(atBottom: false, of: [])
        #expect(!followsAwayFromBottom)
        #expect(!state.isFollowingLatest)
        state.beginUserScroll()
        let followsAtBottom = state.endUserScroll(atBottom: true, of: [])
        #expect(followsAtBottom)
        #expect(state.isFollowingLatest)
        state.revealRow()
        state.followLatest()
        #expect(state.isFollowingLatest)
    }

    @Test func restingOnANewerHistoryEdgeKeepsReadingInsteadOfFollowing() {
        let latest = ChatStreamItem.message(ChatMessage(role: .codex, text: "Loaded page"))
        var state = TranscriptFollowState()
        state.beginUserScroll()
        let followsAtNewerEdge = state.endUserScroll(atBottom: true, of: [latest, .historyEdge(HistoryEdge(kind: .newer, cursor: "later"))])
        #expect(!followsAtNewerEdge)
        #expect(!state.isFollowingLatest)
        state.beginUserScroll()
        let followsAtLatest = state.endUserScroll(atBottom: true, of: [latest])
        #expect(followsAtLatest)
    }

    @Test func aPageAboveACompleteWindowWaitsUpToItsLastMessage() {
        let first = ChatMessage(role: .user, text: "First loaded question")
        let reply = ChatMessage(role: .codex, text: "First loaded reply")
        let window: [TranscriptRow] = [.content(.message(first)), .content(.message(reply))]
        let firstID = ChatStreamItem.message(first).id
        #expect(TranscriptRow.completeStart(firstMessageID: firstID, in: [gap] + window) == 0)
        let splitSection = TranscriptRow.content(.historyEdge(HistoryEdge(kind: .reload(turnID: "turn"), cursor: nil)))
        #expect(TranscriptRow.completeStart(firstMessageID: firstID,
            in: [gap, message(.user, 10), message(.codex, 10), splitSection] + window) == 3)
        #expect(TranscriptRow.completeStart(firstMessageID: firstID, in: [gap, message(.codex, 10)]) == 0)
        #expect(TranscriptRow.completeStart(firstMessageID: nil, in: [gap, message(.codex, 10)] + window) == 0)
    }

    @Test func anAutomaticHistoryReadDoesNotEndTheUsersDrag() {
        var state = TranscriptFollowState()
        state.beginUserScroll()
        state.readHistory()
        #expect(state.isUserScrolling)
        #expect(!state.isFollowingLatest)
        let follows = state.endUserScroll(atBottom: true, of: [])
        #expect(follows)
        #expect(!state.isUserScrolling)
    }

}
