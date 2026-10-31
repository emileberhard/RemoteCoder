import Foundation
import Testing
@testable import RemoteCoderCore

struct StreamingRevealTests {
    @Test func unitsStartSeventyMillisecondsApartUntilTheBacklogPassesThreeHundred() {
        var schedule = StreamingRevealSchedule()
        let starts = (0..<7).map { _ in schedule.start(at: 10) }
        let expected = [10, 10.07, 10.14, 10.21, 10.28, 10.35, 10.385]
        #expect(zip(starts, expected).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test func aUnitAfterAPauseStartsImmediately() {
        var schedule = StreamingRevealSchedule()
        _ = schedule.start(at: 10)
        #expect(schedule.start(at: 12) == 12)
    }

    @Test func aFastStreamStaysLessThanASecondBehind() {
        var schedule = StreamingRevealSchedule()
        var lag: TimeInterval = 0
        for publication in 0..<125 {
            let now = Double(publication) * 0.08
            for _ in 0..<10 { lag = max(lag, schedule.start(at: now) - now) }
        }
        #expect(lag > StreamingRevealSchedule.backlogThreshold)
        #expect(lag < 0.8)
    }

    @Test func unitsSplitAtWordStartsAndKeepTrailingWhitespace() {
        #expect(StreamingRevealText.units(in: "Hej 👋🏽 då", from: 0, limit: 48) == [0..<4, 4..<9, 9..<11])
        #expect(StreamingRevealText.units(in: "Hello world", from: 0, limit: 48) == [0..<6, 6..<11])
        #expect(StreamingRevealText.units(in: "Hello world", from: 3, limit: 48) == [3..<6, 6..<11])
        #expect(StreamingRevealText.units(in: "ab  cd\nef", from: 2, limit: 48) == [4..<7, 7..<9])
        #expect(StreamingRevealText.units(in: "ab   ", from: 2, limit: 48).isEmpty)
        #expect(StreamingRevealText.units(in: "ab", from: 2, limit: 48).isEmpty)
    }

    @Test func aLargeArrivalMergesIntoBoundedContiguousUnits() {
        let text = (0..<100).map { "w\($0)" }.joined(separator: " ")
        let units = StreamingRevealText.units(in: text, from: 0, limit: 10)
        #expect(units.count == 10)
        #expect(units.first?.lowerBound == 0)
        #expect(units.last?.upperBound == text.utf16.count)
        #expect(zip(units, units.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }

    @Test func prefixesAndWordContinuationCompareCharacters() {
        #expect(StreamingRevealText.commonPrefixLength("Hello wor", "Hello world") == 9)
        #expect(StreamingRevealText.commonPrefixLength("[link", "link") == 0)
        #expect(StreamingRevealText.commonPrefixLength("👋🏽 e", "👋🏽 e\u{301}") == 5)
        #expect(StreamingRevealText.continuesWord("👋🏽a", at: 4))
        #expect(StreamingRevealText.continuesWord("Hello", at: 3))
        #expect(!StreamingRevealText.continuesWord("Hel lo", at: 3))
        #expect(!StreamingRevealText.continuesWord("Hello", at: 0))
        #expect(!StreamingRevealText.continuesWord("Hello", at: 5))
    }
}
