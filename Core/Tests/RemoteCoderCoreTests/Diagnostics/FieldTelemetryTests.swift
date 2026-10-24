import Darwin
import Foundation
import Testing
@testable import RemoteCoderCore

struct FieldTelemetryTests {
    private let context = UsageContext(scene: .active, surface: .chat, turnRunningVisible: false, voiceCall: false,
                                       thermal: .nominal, lowPower: false, batteryPercent: nil, charging: nil,
                                       brightnessPercent: nil, network: .wifi, route: .lan)

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func telemetryBatches(in directory: URL) throws -> [[[String: Any]]] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-telemetry.jsonl") }
            .map { url in
                try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                    try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
                }
            }
            .sorted { ($0.dropFirst().first?["seq"] as? Int ?? 0) < ($1.dropFirst().first?["seq"] as? Int ?? 0) }
    }

    private func sample(_ reason: ProcessSample.Reason = .interval) -> TelemetryRecord {
        .sample(ProcessSample(reason: reason, resources: ProcessResources(cpuUserNanoseconds: 2, cpuSystemNanoseconds: 1,
            interruptWakeups: 3, idleWakeups: 4, timerWakeups: 5, footprintBytes: 6), readNanoseconds: 7,
            persistence: [.checkpoints: PersistenceMetrics.Counters(writes: 1, bytes: 10)], mixed: false, context: context))
    }

    @Test func machCPUTimeMatchesTheKernelsResourceUsage() throws {
        var spin = 0.0
        let deadline = ContinuousClock.now + .milliseconds(30)
        while ContinuousClock.now < deadline { spin += sin(spin) }
        #expect(spin.isFinite)
        let resources = try #require(ProcessResources.current())
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let rusageNanoseconds = (UInt64(usage.ru_utime.tv_sec) + UInt64(usage.ru_stime.tv_sec)) * 1_000_000_000
            + (UInt64(usage.ru_utime.tv_usec) + UInt64(usage.ru_stime.tv_usec)) * 1_000
        let difference = abs(Double(resources.cpuNanoseconds) - Double(rusageNanoseconds))
        #expect(difference < max(50_000_000, Double(rusageNanoseconds) * 0.1),
                "task_info \(resources.cpuNanoseconds) ns vs getrusage \(rusageNanoseconds) ns")
        #expect(resources.footprintBytes > 0)
    }

    @Test func aFlushedBatchStartsWithItsRunAndKeepsSequenceOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        outbox.telemetry.record(sample(.launch))
        outbox.telemetry.record(sample(.context))
        await outbox.drain(reason: "test")
        await outbox.drain(reason: "test")
        let batches = try telemetryBatches(in: directory)
        try #require(batches.count == 3)
        let first = batches[0]
        #expect(first.map { $0["recordType"] as? String } == ["run", "sample", "sample"])
        #expect(first[0]["flushedThroughSeq"] as? Int == 2)
        #expect(first.dropFirst().map { $0["seq"] as? Int } == [1, 2])
        #expect((first[1]["persistence"] as? [String: Any])?["checkpoints"] != nil)
        #expect((first[1]["context"] as? [String: Any])?["batteryPercent"] == nil)
        let second = batches[1]
        #expect(second.map { $0["recordType"] as? String } == ["run", "export"])
        #expect(second[1]["reason"] as? String == "test")
        #expect(second[1]["seq"] as? Int == 3)
        #expect(batches[2].dropFirst().map { $0["seq"] as? Int } == [4])
        #expect(Set(batches.map { $0[0]["runID"] as? String }).count == 1)
    }

    @Test func aFullBufferKeepsTheNewestRecordsAndReportsTheLoss() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = DiagnosticsOutbox(directory: directory, deviceLabel: { "test-device" })
        for _ in 0..<300 { outbox.telemetry.record(sample()) }
        await outbox.drain(reason: "test")
        let batch = try #require(try telemetryBatches(in: directory).first)
        let samples = batch.filter { $0["recordType"] as? String == "sample" }
        #expect(samples.count == 256)
        #expect(samples.first?["seq"] as? Int == 45)
        let loss = try #require(batch.first { $0["recordType"] as? String == "loss" })
        #expect(loss["what"] as? String == "telemetryRecords")
        #expect(loss["count"] as? Int == 44)
        #expect(loss["seq"] as? Int == 301)
    }

    @Test func evictionTakesRawLogsBeforeTelemetryAndMetricKit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Data(repeating: 0x61, count: 4_000)
        let small = Data(String(repeating: "{}\n", count: 33).utf8)
        for (name, contents) in [("001000000000000-aaaaaaaa.jsonl", log), ("001000000000001-bbbbbbbb-telemetry.jsonl", small),
                                 ("001000000000002-mk-cccc.jsonl", small), ("001000000000003-dddddddd.jsonl", log)] {
            try contents.write(to: directory.appendingPathComponent(name))
        }
        let outbox = DiagnosticsOutbox(directory: directory, storedByteLimit: 4_000, deviceLabel: { "test-device" })
        try await outbox.enqueue(line: Data("{}\n".utf8), kind: "call")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(!remaining.contains("001000000000000-aaaaaaaa.jsonl"))
        #expect(!remaining.contains("001000000000003-dddddddd.jsonl"))
        #expect(remaining.contains("001000000000001-bbbbbbbb-telemetry.jsonl"))
        #expect(remaining.contains("001000000000002-mk-cccc.jsonl"))
        await outbox.drain(reason: "test")
        let losses = try telemetryBatches(in: directory).flatMap { $0 }.filter { $0["recordType"] as? String == "loss" }
        #expect(losses.contains { $0["what"] as? String == "logSegment" && $0["count"] as? Int == 2 })
    }

    @MainActor @Test func aChangeCutShortByBackgroundingMarksItsIntervalMixed() {
        let buffer = TelemetryBuffer(runID: "test")
        let resources = ProcessResources(cpuUserNanoseconds: 1, cpuSystemNanoseconds: 1, interruptWakeups: 0,
                                         idleWakeups: 0, timerWakeups: 0, footprintBytes: 1)
        let sampler = ProcessResourceSampler(recorder: buffer, read: { resources })
        sampler.update(context)
        var changed = context
        changed.turnRunningVisible = true
        sampler.update(changed)
        var background = changed
        background.scene = .background
        sampler.update(background)
        var returning = background
        returning.scene = .active
        sampler.update(returning)
        sampler.stop()
        let samples = buffer.take().compactMap { line -> ProcessSample? in
            if case .sample(let sample) = line.record { return sample }
            return nil
        }
        #expect(samples.map(\.reason) == [.launch, .background, .foreground])
        #expect(samples.map(\.mixed) == [false, true, false])
        #expect(samples[1].context.turnRunningVisible == true)
    }

    @MainActor @Test func aTransitionWhoseReadFailedMarksTheNextIntervalMixed() {
        let buffer = TelemetryBuffer(runID: "test")
        let resources = ProcessResources(cpuUserNanoseconds: 1, cpuSystemNanoseconds: 1, interruptWakeups: 0,
                                         idleWakeups: 0, timerWakeups: 0, footprintBytes: 1)
        var reads = 0
        let sampler = ProcessResourceSampler(recorder: buffer, read: {
            reads += 1
            return reads == 2 ? nil : resources
        })
        sampler.update(context)
        var background = context
        background.scene = .background
        sampler.update(background)
        sampler.update(context)
        sampler.stop()
        let samples = buffer.take().compactMap { line -> ProcessSample? in
            if case .sample(let sample) = line.record { return sample }
            return nil
        }
        #expect(samples.map(\.reason) == [.launch, .foreground])
        #expect(samples.map(\.mixed) == [false, true])
    }
}
