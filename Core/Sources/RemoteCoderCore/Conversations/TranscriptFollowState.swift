struct TranscriptFollowState {
    private(set) var isFollowingLatest = true
    private(set) var isUserScrolling = false

    mutating func beginUserScroll() {
        isUserScrolling = true
    }

    mutating func userScrollMoved(atBottom: Bool) {
        guard isUserScrolling, !atBottom else { return }
        isFollowingLatest = false
    }

    mutating func endUserScroll(atBottom: Bool, of items: [ChatStreamItem]) -> Bool {
        guard isUserScrolling else { return false }
        isUserScrolling = false
        isFollowingLatest = atBottom && !items.endsAtNewerHistoryEdge
        return isFollowingLatest
    }

    mutating func readHistory() {
        isFollowingLatest = false
    }

    mutating func revealRow() {
        isUserScrolling = false
        isFollowingLatest = false
    }

    mutating func followLatest() {
        isUserScrolling = false
        isFollowingLatest = true
    }
}
