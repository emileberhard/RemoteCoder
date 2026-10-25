import Foundation
import Testing
@testable import RemoteCoderCore

struct GatewayReconnectPolicyTests {
    private let start = ContinuousClock.now

    @Test func failuresClimbTheLadderAndSettleAtAMinute() {
        var policy = GatewayReconnectPolicy(jitter: { 1 })
        let delays = (0..<9).map { _ in policy.failed(at: start, restartingSince: nil) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
        #expect(policy.notBefore == start + .seconds(60))
        #expect(!policy.permits(at: start + .seconds(59)))
        #expect(policy.permits(at: start + .seconds(60)))
    }

    @Test func jitterSpreadsEachDelayAcrossTheUpperHalfOfItsCeiling() {
        var policy = GatewayReconnectPolicy(jitter: { 0.5 })
        let delays = (0..<2).map { _ in policy.failed(at: start, restartingSince: nil) }
        #expect(delays == [.milliseconds(500), .seconds(1)])
    }

    @Test func aPlannedRestartRetriesFastForItsPhaseThenContinuesTheLadder() {
        var policy = GatewayReconnectPolicy(jitter: { 1 })
        let fast = (0..<5).map { policy.failed(at: start + .seconds($0 * 8), restartingSince: start) }
        #expect(fast == [1, 2, 4, 4, 4].map { Duration.seconds($0) })
        let afterPhase = policy.failed(at: start + .seconds(46), restartingSince: start)
        #expect(afterPhase == .seconds(8))
    }

    @Test func aShortLivedConnectionCountsAsAFailureAndAStableOneResetsTheStreak() {
        var policy = GatewayReconnectPolicy(jitter: { 1 })
        policy.failed(at: start, restartingSince: nil)
        policy.failed(at: start, restartingSince: nil)
        policy.connected(at: start + .seconds(3))
        #expect(policy.permits(at: start + .seconds(3)))

        policy.disconnected(at: start + .seconds(5), restartingSince: nil)
        #expect(policy.failures == 3)
        #expect(policy.notBefore == start + .seconds(9))

        policy.disconnected(at: start + .seconds(6), restartingSince: nil)
        #expect(policy.failures == 3)

        policy.connected(at: start + .seconds(10))
        policy.disconnected(at: start + .seconds(40), restartingSince: nil)
        #expect(policy.failures == 0)
        #expect(policy.permits(at: start + .seconds(40)))
    }

    @Test func expeditingSkipsOneWaitAtMostEveryFiveSeconds() {
        var policy = GatewayReconnectPolicy(jitter: { 1 })
        let idle = policy.expedite(at: start)
        #expect(!idle)

        for _ in 0..<5 { policy.failed(at: start, restartingSince: nil) }
        let first = policy.expedite(at: start + .seconds(1))
        #expect(first)
        #expect(policy.permits(at: start + .seconds(1)))

        policy.failed(at: start + .seconds(2), restartingSince: nil)
        let tooSoon = policy.expedite(at: start + .seconds(3))
        #expect(!tooSoon)
        #expect(!policy.permits(at: start + .seconds(3)))
        let later = policy.expedite(at: start + .seconds(6))
        #expect(later)
    }
}
