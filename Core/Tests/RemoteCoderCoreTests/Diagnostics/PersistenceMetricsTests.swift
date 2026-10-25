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

        let context = UsageContext(scene: .active, surface: .chat, turnRunningVisible: true, voiceCall: false,
            thermal: .nominal, lowPower: false)
        let resources = ProcessResources(cpuUserNanoseconds: 1, cpuSystemNanoseconds: 1, gpuNanoseconds: 0,
            interruptWakeups: 0, idleWakeups: 0, timerWakeups: 0, footprintBytes: 1)
        let line = TelemetryLine(runID: "test", seq: 1, at: .now, monoNs: 1, record: .sample(
            ProcessSample(reason: .interval, resources: resources, readNanoseconds: 1,
                persistence: metrics.snapshot(), mixed: false, context: context)))
        let data = try JSONEncoder().encode(line)
        #expect(data.count < 4_096)
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

    @Test func olderPersistenceCountersKeepCheckpointPhasesUnknown() throws {
        let legacy = Data(#"{"writes":3,"bytes":4000,"writesWithoutByteCount":0,"skipped":1,"failures":0,"milliseconds":20}"#.utf8)
        let counters = try JSONDecoder().decode(PersistenceMetrics.Counters.self, from: legacy)
        #expect(counters.writes == 3)
        #expect(counters.checkpoint == nil)
        let roundTrip = try JSONDecoder().decode(PersistenceMetrics.Counters.self, from: JSONEncoder().encode(counters))
        #expect(roundTrip == counters)
    }
}
