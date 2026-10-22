import Foundation
import Testing
@testable import RemoteCoder

struct HistoryRefreshTimingTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func sleepsUntilTheFreshnessDeadlineRatherThanPollingEverySecond() {
        #expect(HistoryRefreshTiming.delay(after: now, now: now) == .seconds(15))
        #expect(HistoryRefreshTiming.delay(after: now, now: now.addingTimeInterval(12)) == .seconds(3))
    }

    @Test func failedAndInFlightRefreshesCannotCreateAOneSecondRetryLoop() {
        #expect(HistoryRefreshTiming.delay(after: nil, now: now) == .seconds(15))
        #expect(HistoryRefreshTiming.delay(after: now.addingTimeInterval(-60), now: now) == .seconds(15))
        #expect(HistoryRefreshTiming.delay(after: now.addingTimeInterval(-15), now: now) == .seconds(15))
    }

    @Test func clockChangesCannotPostponeCheckingBeyondTheFreshnessBudget() {
        #expect(HistoryRefreshTiming.delay(after: now.addingTimeInterval(3_600), now: now) == .seconds(15))
    }
}
