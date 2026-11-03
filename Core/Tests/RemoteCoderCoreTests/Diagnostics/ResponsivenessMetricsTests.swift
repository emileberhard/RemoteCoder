import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ResponsivenessMetricsTests {
    private static let millisecond: UInt64 = 1_000_000

    @Test func busyPeriodsRunFromWakeToSleepAndCountEveryThresholdTheyReach() {
        let periods = MainRunLoopBusyPeriods()
        var now: UInt64 = 1_000 * Self.millisecond
        for duration: UInt64 in [5 * Self.millisecond, 17 * Self.millisecond - 1, 20 * Self.millisecond,
                                 120 * Self.millisecond, 300 * Self.millisecond, 2_500 * Self.millisecond] {
            periods.wake(at: now)
            now += duration
            periods.sleep(at: now)
            now += 10 * Self.millisecond
        }

        #expect(periods.completed.busyPeriods == 6)
        #expect(periods.completed.busyNanoseconds == 2_962 * Self.millisecond - 1)
        #expect(periods.completed.hangNanoseconds == 2_800 * Self.millisecond)
        #expect(periods.completed.busyPeriodsAtLeast == [4, 3, 3, 3, 2, 1, 1, 1])
    }

    @Test func aSampleInsideABusyPeriodCountsItsTimeSoFarAndStaysMonotonic() {
        let periods = MainRunLoopBusyPeriods()
        periods.wake(at: 0)

        let during = periods.counters(at: 800 * Self.millisecond)
        periods.sleep(at: 900 * Self.millisecond)
        let after = periods.counters(at: 1_000 * Self.millisecond)

        #expect(during.busyNanoseconds == 800 * Self.millisecond)
        #expect(during.hangNanoseconds == 800 * Self.millisecond)
        #expect(during.busyPeriods == 0)
        #expect(after.busyNanoseconds == 900 * Self.millisecond)
        #expect(after.hangNanoseconds == 900 * Self.millisecond)
        #expect(after.busyPeriods == 1)
    }

    @Test func aSleepWithoutItsWakeIsNotAPeriod() {
        let periods = MainRunLoopBusyPeriods()
        periods.sleep(at: 50 * Self.millisecond)
        periods.wake(at: 100 * Self.millisecond)
        periods.sleep(at: 130 * Self.millisecond)
        periods.sleep(at: 400 * Self.millisecond)

        #expect(periods.completed.busyPeriods == 1)
        #expect(periods.completed.busyNanoseconds == 30 * Self.millisecond)
    }

    @Test func historyOpensFillEveryBoundTheyFitWithinAndCountAbandonsSeparately() {
        let metrics = ResponsivenessMetrics()
        let start = ContinuousClock.now
        for elapsed in [Duration.milliseconds(80), .microseconds(50_999), .milliseconds(450), .seconds(5)] {
            metrics.historyOpenReachedContent(metrics.historyOpenStarted(at: start), at: start + elapsed)
        }
        metrics.historyOpenAbandoned()

        #expect(metrics.historyOpens.completed == 4)
        #expect(metrics.historyOpens.abandoned == 1)
        #expect(metrics.historyOpens.completedNanoseconds == 5_580_999_000)
        #expect(metrics.historyOpens.completedWithin == [0, 2, 2, 2, 2, 3, 3, 3, 3, 3])
    }

    @Test func anOpenThatSpansBackgroundingIsAbandoned() {
        let metrics = ResponsivenessMetrics()
        let active = UsageContext(scene: .active, surface: .chat, turnRunningVisible: false, voiceCall: false,
                                  thermal: .nominal, lowPower: false)
        var background = active
        background.scene = .background
        let start = ContinuousClock.now
        metrics.contextChanged(active)
        let open = metrics.historyOpenStarted(at: start)
        metrics.contextChanged(background)
        metrics.contextChanged(active)
        metrics.historyOpenReachedContent(open, at: start + .seconds(90))

        #expect(metrics.historyOpens.completed == 0)
        #expect(metrics.historyOpens.abandoned == 1)
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
        var mainRunLoop = MainRunLoopBusyPeriods.Counters()
        mainRunLoop.busyPeriods = 3
        mainRunLoop.busyPeriodsAtLeast[3] = 1
        let context = UsageContext(scene: .active, surface: .chat, turnRunningVisible: false, voiceCall: false,
                                   thermal: .nominal, lowPower: false)
        let resources = ProcessResources(cpuUserNanoseconds: 1, cpuSystemNanoseconds: 1, interruptWakeups: 0,
                                         idleWakeups: 0, timerWakeups: 0, footprintBytes: 1)
        let line = TelemetryLine(runID: "test", seq: 1, at: .now, monoNs: 1, record: .sample(ProcessSample(
            reason: .interval, resources: resources, mainThreadCPUNanoseconds: 7, readNanoseconds: 1, persistence: [:],
            responsiveness: .init(mainRunLoop: mainRunLoop, historyOpens: .init()),
            workload: Workload(runningTurnNanoseconds: nil, streamedDeltas: 4, streamedBytes: 40),
            mixed: false, context: context)))

        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(line)) as? [String: Any])

        #expect(json["mainThreadCpuNs"] as? Int == 7)
        let encodedRunLoop = try #require(json["mainRunLoop"] as? [String: Any])
        #expect(encodedRunLoop["busyPeriods"] as? Int == 3)
        #expect(encodedRunLoop["busyPeriodsAtLeastMs"] as? [String: Int]
            == ["17": 0, "33": 0, "50": 0, "100": 1, "250": 0, "500": 0, "1000": 0, "2000": 0])
        let opens = try #require(json["historyOpens"] as? [String: Any])
        #expect((opens["completedWithinMs"] as? [String: Int])?.count == 10)
        #expect(json["workload"] as? [String: Int] == ["streamedDeltas": 4, "streamedBytes": 40])
    }
}
