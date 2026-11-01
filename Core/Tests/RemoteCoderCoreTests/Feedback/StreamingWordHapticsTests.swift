import Testing
@testable import RemoteCoderCore

struct StreamingWordHapticsTests {
    @Test func sixDistinctWordStartsSpanPublicationsWithADecayingRamp() {
        var haptics = StreamingWordHaptics()
        let starts = [10.0, 10.07, 10.14, 10.21, 10.28, 10.35, 10.42]
        let expected: [Float] = [1, 0.84, 0.68, 0.52, 0.36, 0.2]
        for index in starts.indices {
            haptics.update(begins: Array(starts.prefix(index + 1)))
            let punch = haptics.next(at: starts[index] + 0.01)
            if index < expected.count {
                #expect(punch.map { abs($0 - expected[index]) < 0.00001 } == true)
            } else {
                #expect(punch == nil)
            }
        }
        #expect(!haptics.hasPending)
        haptics.update(begins: [20])
        #expect(haptics.next(at: 20.01) == nil)
    }

    @Test func aDelayedFrameChoosesOnlyTheNewestFreshWordWithoutCatchingUp() {
        var haptics = StreamingWordHaptics()
        haptics.update(begins: [10, 10.07, 10.14])
        #expect(haptics.next(at: 10.2).map { abs($0 - 0.68) < 0.00001 } == true)
        #expect(haptics.next(at: 10.23) == nil)
        #expect(!haptics.hasPending)
    }

    @Test func continuationFragmentsAndReadersCannotRearmAPlayedWord() {
        var haptics = StreamingWordHaptics()
        haptics.update(begins: [10, 10.07])
        #expect(haptics.next(at: 10.01) == 1)
        haptics.update(begins: [10, 10.07])
        #expect(haptics.next(at: 10.04) == nil)
        #expect(haptics.next(at: 10.08).map { abs($0 - 0.84) < 0.00001 } == true)
    }

    @Test func staleOrSuppressedStartsNeverReplayButFreshStartsUseTheRemainingBudget() {
        var haptics = StreamingWordHaptics()
        haptics.update(begins: [10])
        #expect(haptics.next(at: 10) == nil)
        #expect(haptics.next(at: 10.2) == nil)
        haptics.update(begins: [10, 11])
        #expect(haptics.next(at: 11.01).map { abs($0 - 0.84) < 0.00001 } == true)
        haptics.update(begins: [11, 11.07])
        haptics.discard()
        haptics.update(begins: [11, 11.07, 11.14])
        #expect(haptics.next(at: 11.15).map { abs($0 - 0.52) < 0.00001 } == true)
        #expect(haptics.next(at: 11.18) == nil)
    }
}
