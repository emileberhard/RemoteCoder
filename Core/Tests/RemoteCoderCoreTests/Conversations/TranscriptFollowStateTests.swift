import Testing
@testable import RemoteCoderCore

struct TranscriptFollowStateTests {
    @Test func trackingAtTheBottomDoesNotEnterHistoryReading() {
        var state = TranscriptFollowState()
        for _ in 0..<3 {
            state.beginUserScroll()
            state.userScrollMoved(atBottom: true)
            #expect(state.isUserScrolling)
            #expect(state.isFollowingLatest)
            let refollowed = state.endUserScroll(atBottom: true, of: [])
            #expect(refollowed)
            #expect(state.isFollowingLatest)
        }
    }

    @Test func displacementAwayFromTheBottomEntersHistoryReading() {
        var state = TranscriptFollowState()
        state.beginUserScroll()
        state.userScrollMoved(atBottom: false)
        #expect(!state.isFollowingLatest)
        let refollowed = state.endUserScroll(atBottom: false, of: [])
        #expect(!refollowed)
        #expect(!state.isUserScrolling)
        #expect(!state.isFollowingLatest)
        state.followLatest()
        #expect(state.isFollowingLatest)
    }

    @Test func passiveGeometryDoesNotChangeFollowing() {
        var state = TranscriptFollowState()
        state.userScrollMoved(atBottom: false)
        #expect(state.isFollowingLatest)
    }

    @Test func returningToTheLoadedNewerEdgeDoesNotFollowLatest() {
        var state = TranscriptFollowState()
        state.beginUserScroll()
        state.userScrollMoved(atBottom: false)
        let items = [ChatStreamItem.historyEdge(HistoryEdge(kind: .newer, cursor: "later"))]
        let refollowed = state.endUserScroll(atBottom: true, of: items)
        #expect(!refollowed)
        #expect(!state.isFollowingLatest)
    }
}
