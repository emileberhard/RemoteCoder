import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ResponsivenessMetricsTests {
    private static let millisecond: UInt64 = 1_000_000

    @Test func busyPeriodsRunFromWakeToSleepAndCountEveryThresholdTheyReach() {
        let metrics = ResponsivenessMetrics()
        var now: UInt64 = 1_000 * Self.millisecond
        for milliseconds: UInt64 in [5, 20, 120, 300, 2_500] {
            metrics.wake(at: now)
            now += milliseconds * Self.millisecond
            metrics.sleep(at: now)
            now += 10 * Self.millisecond
        }

        #expect(metrics.runLoop.busyPeriods == 5)
        #expect(metrics.runLoop.busyNanoseconds == 2_945 * Self.millisecond)
        #expect(metrics.runLoop.hangNanoseconds == 2_800 * Self.millisecond)
        #expect(metrics.runLoop.busyPeriodsAtLeast == [4, 3, 3, 3, 2, 1, 1, 1])
    }

    @Test func aSleepWithoutItsWakeIsNotAPeriod() {
        let metrics = ResponsivenessMetrics()
        metrics.sleep(at: 50 * Self.millisecond)
        metrics.wake(at: 100 * Self.millisecond)
        metrics.sleep(at: 130 * Self.millisecond)
        metrics.sleep(at: 400 * Self.millisecond)

        #expect(metrics.runLoop.busyPeriods == 1)
        #expect(metrics.runLoop.busyNanoseconds == 30 * Self.millisecond)
        #expect(metrics.runLoop.busyPeriodsAtLeast == [1, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func switchesFillEveryBoundTheyFitWithinAndCountAbandonsSeparately() {
        let metrics = ResponsivenessMetrics()
        metrics.switchCompleted(after: .milliseconds(80))
        metrics.switchCompleted(after: .milliseconds(450))
        metrics.switchCompleted(after: .seconds(5))
        metrics.switchAbandoned()

        #expect(metrics.switches.completed == 3)
        #expect(metrics.switches.abandoned == 1)
        #expect(metrics.switches.completedNanoseconds == 5_530 * Self.millisecond)
        #expect(metrics.switches.completedWithin == [0, 1, 1, 1, 1, 2, 2, 2, 2, 2])
    }

    @Test func runningTurnsIntegrateOverTheTimeEachCountHeld() {
        let start = ContinuousClock.now
        var integral = RunningTurnIntegral()
        integral.accrue(to: start)
        #expect(integral.current == nil)
        integral.set(2, at: start + .seconds(1))
        integral.set(1, at: start + .seconds(4))
        integral.accrue(to: start + .seconds(6))

        #expect(integral.current == 1)
        #expect(integral.nanoseconds == 8_000_000_000)
    }

    @Test func aSampleEncodesTheNewFieldsAndOmitsUnknownTurns() throws {
        var runLoop = ResponsivenessMetrics.RunLoop()
        runLoop.busyPeriods = 3
        runLoop.busyPeriodsAtLeast[3] = 1
        let context = UsageContext(scene: .active, surface: .chat, turnRunningVisible: false, voiceCall: false,
                                   thermal: .nominal, lowPower: false)
        let resources = ProcessResources(cpuUserNanoseconds: 1, cpuSystemNanoseconds: 1, interruptWakeups: 0,
                                         idleWakeups: 0, timerWakeups: 0, footprintBytes: 1, mainThreadCPUNanoseconds: 7)
        let line = TelemetryLine(runID: "test", seq: 1, at: .now, monoNs: 1, record: .sample(ProcessSample(
            reason: .interval, resources: resources, readNanoseconds: 1, persistence: [:],
            responsiveness: .init(runLoop: runLoop, switches: .init()),
            workload: Workload(runningTurns: nil, runningTurnNanoseconds: nil, streamedDeltas: 4, streamedBytes: 40),
            mixed: false, context: context)))

        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(line)) as? [String: Any])

        #expect(json["mainThreadCpuNs"] as? Int == 7)
        let encodedRunLoop = try #require(json["runLoop"] as? [String: Any])
        #expect(encodedRunLoop["busyPeriods"] as? Int == 3)
        #expect(encodedRunLoop["busyPeriodsAtLeastMs"] as? [String: Int]
            == ["17": 0, "33": 0, "50": 0, "100": 1, "250": 0, "500": 0, "1000": 0, "2000": 0])
        let switches = try #require(json["switches"] as? [String: Any])
        #expect((switches["completedWithinMs"] as? [String: Int])?.count == 10)
        #expect(json["workload"] as? [String: Int] == ["streamedDeltas": 4, "streamedBytes": 40])
    }
}
