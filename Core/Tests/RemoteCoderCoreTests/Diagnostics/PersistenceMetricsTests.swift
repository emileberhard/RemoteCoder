import Foundation
import Testing
@testable import RemoteCoderCore

struct PersistenceMetricsTests {
    @Test func checkpointPhasesStayCumulativeAndReachFieldTelemetryWithoutSamples() throws {
        let metrics = PersistenceMetrics()
        for index in 0..<10_000 {
            metrics.recordCheckpointPhase(.encodeRun, elapsed: .milliseconds(index < 6_000 ? 2 : 10))
        }
        metrics.recordCheckpointWrite(inputBytes: 1_000_000, newPayloadBytes: 4_000,
            chunking: .milliseconds(3), sqlCommit: .milliseconds(7))
        metrics.recordCheckpointWrite(inputBytes: 1_000_006, newPayloadBytes: 4_006,
            chunking: .milliseconds(4), sqlCommit: .milliseconds(8))
        let checkpoint = try #require(metrics.snapshot()[.checkpoints]?.checkpoint)
        #expect(checkpoint.writes == 2)
        #expect(checkpoint.inputBytes == 2_000_006)
        #expect(checkpoint.newPayloadBytes == 8_006)
        let encode = try #require(checkpoint.phases["encodeRun"])
        #expect(encode.count == 10_000)
        #expect(encode.milliseconds == 52_000)
        #expect(encode.p50UpperBoundMilliseconds >= 2 && encode.p50UpperBoundMilliseconds < 3)
        #expect(encode.maxMilliseconds == 10)
        #expect(checkpoint.phases["chunking"]?.count == 2)
        #expect(checkpoint.phases["sqlCommit"]?.milliseconds == 15)
        #expect(checkpoint.phases["predecessorWait"] == nil)

        let data = try JSONEncoder().encode(Self.sampleLine(persistence: metrics.snapshot(), magnitude: 1))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let persistence = try #require(json["persistence"] as? [String: [String: Any]])
        let exported = try #require(persistence["checkpoints"]?["checkpoint"] as? [String: Any])
        #expect(exported["inputBytes"] as? Int == 2_000_006)
        let phases = try #require(exported["phases"] as? [String: [String: Any]])
        #expect(phases["encodeRun"]?["count"] as? Int == 10_000)
        #expect(phases["encodeRun"]?["maxMilliseconds"] as? Double == 10)
        #expect(phases["encodeRun"]?["samples"] == nil)
        #expect(phases["encodeRun"]?["buckets"] == nil)
    }

    @Test func aSampleWithEveryFieldAtLongRunMagnitudesFitsTheLineBudget() throws {
        let metrics = PersistenceMetrics()
        for owner in PersistenceMetrics.Owner.allCases {
            for _ in 0..<3 {
                metrics.wrote(owner, bytes: 987_654_321, elapsed: .nanoseconds(123_456_789))
                metrics.wrote(owner, bytes: nil, elapsed: .nanoseconds(987_654_321))
                metrics.skipped(owner)
                metrics.failed(owner)
            }
        }
        for phase in Self.checkpointPhases {
            for index in 0..<200 {
                metrics.recordCheckpointPhase(phase, elapsed: .nanoseconds(1_234_567 + index * 7_919))
            }
        }
        metrics.recordCheckpointWrite(inputBytes: 9_876_543_210, newPayloadBytes: 1_234_567_890,
            chunking: .nanoseconds(3_333_333), sqlCommit: .nanoseconds(7_777_777))
        metrics.recordReadmittedHistory(bytes: 9_876_543_210)
        metrics.recordDeferredHistory(bytes: 9_876_543_210)
        metrics.recordHistoryShed()
        metrics.recordCheckpointCompaction()
        let snapshot = metrics.snapshot()
        #expect(snapshot.count == PersistenceMetrics.Owner.allCases.count)
        #expect(snapshot[.checkpoints]?.checkpoint?.phases.count == Self.checkpointPhases.count)

        let data = try JSONEncoder().encode(Self.sampleLine(persistence: snapshot, magnitude: 604_800_000_000_000))
        #expect(data.count < 4_096, "sample line is \(data.count) bytes")
    }

    private static let checkpointPhases: [PersistenceMetrics.CheckpointPhase] = [
        .total, .preflight, .predecessorWait, .encodeWait, .encodeQueue, .encodeRun, .encodeResume,
        .admission, .database, .chunking, .sqlCommit, .finalize, .historyShedRead,
    ]

    private static func sampleLine(persistence: [PersistenceMetrics.Owner: PersistenceMetrics.Counters],
                                   magnitude: UInt64) -> TelemetryLine {
        let context = UsageContext(scene: .background, surface: .drawer, turnRunningVisible: true, voiceCall: true,
            recording: true, composing: true, thermal: .critical, lowPower: true, batteryPercent: 100, charging: true,
            brightnessPercent: 100, network: .cellular, route: .restarting)
        let resources = ProcessResources(cpuUserNanoseconds: magnitude, cpuSystemNanoseconds: magnitude,
            interruptWakeups: magnitude, idleWakeups: magnitude, timerWakeups: magnitude, footprintBytes: magnitude)
        var mainRunLoop = MainRunLoopBusyPeriods.Counters()
        mainRunLoop.busyNanoseconds = magnitude
        mainRunLoop.busyPeriods = magnitude
        mainRunLoop.hangNanoseconds = magnitude
        mainRunLoop.busyPeriodsAtLeast = mainRunLoop.busyPeriodsAtLeast.map { _ in magnitude }
        var historyOpens = ResponsivenessMetrics.HistoryOpens()
        historyOpens.completed = magnitude
        historyOpens.abandoned = magnitude
        historyOpens.completedNanoseconds = magnitude
        historyOpens.completedWithin = historyOpens.completedWithin.map { _ in magnitude }
        return TelemetryLine(runID: UUID().uuidString, seq: magnitude, at: .now, monoNs: magnitude,
            record: .sample(ProcessSample(reason: .background, resources: resources, mainThreadCPUNanoseconds: magnitude,
                readNanoseconds: magnitude, persistence: persistence,
                responsiveness: .init(mainRunLoop: mainRunLoop, historyOpens: historyOpens),
                workload: Workload(runningTurnNanoseconds: magnitude, streamedDeltas: magnitude, streamedBytes: magnitude),
                mixed: true, context: context)))
    }

    @Test func olderPersistenceCountersKeepCheckpointPhasesUnknown() throws {
        let legacy = Data(#"{"writes":3,"bytes":4000,"writesWithoutByteCount":0,"skipped":1,"failures":0,"milliseconds":20}"#.utf8)
        let counters = try JSONDecoder().decode(PersistenceMetrics.Counters.self, from: legacy)
        #expect(counters.writes == 3)
        #expect(counters.checkpoint == nil)
        let roundTrip = try JSONDecoder().decode(PersistenceMetrics.Counters.self, from: JSONEncoder().encode(counters))
        #expect(roundTrip == counters)
    }
}
