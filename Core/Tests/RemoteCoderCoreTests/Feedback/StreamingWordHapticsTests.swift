import Testing
@testable import RemoteCoderCore

struct StreamingWordHapticsTests {
    @Test func sixWordStartsUseTheRecoveredIntensityRamp() {
        var haptics = StreamingWordHaptics()
        haptics.update(begins: [10, 10.07, 10.14, 10.21, 10.28, 10.35, 10.42])
        let times = [10.01, 10.08, 10.15, 10.22, 10.29, 10.36]
        let expected: [Float] = [1, 0.84, 0.68, 0.52, 0.36, 0.2]
        for (time, value) in zip(times, expected) {
            #expect(haptics.next(at: time).map { abs($0 - value) < 0.00001 } == true)
        }
        #expect(haptics.next(at: 10.43) == nil)
        #expect(!haptics.hasPending)
    }

    @Test func oneTickChoosesTheNewestDueWordAndKeepsOtherFlagsForLaterFrames() {
        var haptics = StreamingWordHaptics()
        haptics.update(begins: [10, 10.07, 10.14])
        #expect(haptics.next(at: 10.2).map { abs($0 - 0.68) < 0.00001 } == true)
        #expect(haptics.next(at: 10.23).map { abs($0 - 0.84) < 0.00001 } == true)
        #expect(haptics.next(at: 10.26) == 1)
        #expect(haptics.next(at: 10.29) == nil)
    }

    @Test func anUpdateRearmsOnlyWhileTheLastFadingWordIsStillMarked() {
        var haptics = StreamingWordHaptics()
        haptics.update(begins: [10, 10.07])
        #expect(haptics.next(at: 10.01) == 1)
        haptics.update(begins: [10, 10.07])
        #expect(haptics.next(at: 10.04) == 1)
        #expect(haptics.next(at: 10.08) != nil)
        haptics.update(begins: [10, 10.07, 10.14])
        #expect(haptics.next(at: 10.15) == nil)
    }

    @Test func expiredAndSuppressedWordsDoNotReplayOrRestartTheRun() {
        var haptics = StreamingWordHaptics()
        haptics.update(begins: [10, 10.07])
        #expect(haptics.next(at: 10) == nil)
        #expect(haptics.next(at: 11) == nil)
        haptics.update(begins: [12])
        #expect(haptics.next(at: 12.01) == nil)
        var suppressed = StreamingWordHaptics()
        suppressed.update(begins: [10, 10.07])
        suppressed.discard()
        suppressed.update(begins: [10, 10.07, 10.14])
        #expect(suppressed.next(at: 10.15) == nil)
    }
}
