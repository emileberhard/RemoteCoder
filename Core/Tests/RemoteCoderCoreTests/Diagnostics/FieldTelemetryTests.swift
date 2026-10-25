import Darwin
import Foundation
import Synchronization
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
        let outbox = DiagnosticsOutbox(directory: directory, logSink: AppLogSink(), deviceLabel: { "test-device" })
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

    @Test func stateLabelsFollowTheProjectionAndClearInTheBackground() {
        var running = context
        running.turnRunningVisible = true
        #expect(UsageStateLabels(running, conservesEnergy: false)
            == UsageStateLabels(surface: "chat", turn: "running", route: "lan", voice: nil, energy: nil))

        var drawer = running
        drawer.surface = .drawer
        drawer.voiceCall = true
        drawer.route = .relay
        #expect(UsageStateLabels(drawer, conservesEnergy: true)
            == UsageStateLabels(surface: "drawer", turn: "running", route: "relay", voice: "call", energy: "conserving"))

        var inactive = drawer
        inactive.scene = .inactive
        #expect(UsageStateLabels(inactive, conservesEnergy: true) == UsageStateLabels(drawer, conservesEnergy: true))

        var background = drawer
        background.scene = .background
        #expect(UsageStateLabels(background, conservesEnergy: false)
            == UsageStateLabels(surface: nil, turn: nil, route: nil, voice: "call", energy: nil))

        var unknown = context
        unknown.turnRunningVisible = nil
        unknown.route = nil
        let labels = UsageStateLabels(unknown, conservesEnergy: false)
        #expect(labels.turn == nil && labels.route == nil)
    }

    @Test func historyStateShowsAnyOpenBeforePagingAndClearsOnEnteringTheBackground() {
        var operations = HistoryOperations()
        operations.sceneChanged(background: true)
        let paging = operations.begin(.paging, provider: .codex)
        let opening = operations.begin(.opening, provider: .claude)
        operations.sceneChanged(background: false)
        let laterPaging = operations.begin(.paging, provider: .codex)
        #expect(operations.current?.id == opening)
        operations.finish(opening)
        #expect(operations.current?.id == laterPaging)
        operations.finish(laterPaging)
        operations.finish(laterPaging)
        #expect(operations.current?.id == paging)

        operations.sceneChanged(background: true)
        #expect(operations.current == nil)
        let reopened = operations.begin(.opening, provider: .codex)
        #expect(operations.current?.id == reopened)
    }

    @Test func historyReportsTransitionsOnlyWhenTheStateChangesAndOtherwiseTheOperation() {
        var operations = HistoryOperations()
        #expect(operations.report() == nil)
        let first = operations.begin(.opening, provider: .codex)
        #expect(operations.report() == .transition(operations.current))
        let second = operations.begin(.opening, provider: .codex)
        #expect(operations.report() == .operationChanged(second))
        operations.finish(second)
        #expect(operations.report() == .operationChanged(first))
        let claude = operations.begin(.opening, provider: .claude)
        #expect(operations.report() == .transition(operations.current))
        #expect(operations.report() == nil)
        operations.finish(claude)
        operations.finish(first)
        #expect(operations.report() == .transition(nil))
    }

    private func logRecord(_ message: String) -> AppLogRecord {
        AppLogRecord(ts: Date(timeIntervalSince1970: 1_800_000_000), level: "notice", subsystem: AppLogger.subsystem,
                     category: "Fixture", message: message, thread: 1)
    }

    private func logMessages(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.contains("-telemetry") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])["message"] as? String ?? "" }
    }

    @Test func aDrainWritesQueuedRecordsAsALogSegment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = AppLogSink()
        let outbox = DiagnosticsOutbox(directory: directory, logSink: sink, deviceLabel: { "test-device" })
        sink.append(logRecord("first"))
        sink.append(logRecord("second"))
        await outbox.drain(reason: "interval")
        #expect(try logMessages(in: directory) == ["first", "second"])
        let export = try #require(try telemetryBatches(in: directory).flatMap { $0 }.last { $0["recordType"] as? String == "export" })
        #expect(export["logWrite"] as? String == "written")
        #expect(export["kept"] as? Int == 2)
    }

    @Test func aFailedSegmentWriteKeepsTheRecordsForTheNextDrain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = AppLogSink()
        let outbox = DiagnosticsOutbox(directory: directory, logSink: sink, deviceLabel: { "test-device" })
        sink.append(logRecord("kept"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await outbox.drain(reason: "interval")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(try logMessages(in: directory).isEmpty)
        await outbox.drain(reason: "background")
        #expect(try logMessages(in: directory) == ["kept"])
        let exports = try telemetryBatches(in: directory).flatMap { $0 }.filter { $0["recordType"] as? String == "export" }
        #expect(exports.last?["logWrite"] as? String == "written")
    }

    @Test func aFullSinkKeepsTheNewestRecordsAndCountsWhatItDropped() {
        let sink = AppLogSink(byteLimit: 2_000)
        for index in 0..<40 { sink.append(logRecord("record \(index)")) }
        sink.append(logRecord(String(repeating: "x", count: 300)))
        let batch = sink.take()
        #expect(batch.records.last?.message == "record 39")
        #expect(batch.dropped == 40 - batch.records.count + 1)
        #expect(sink.take().records.isEmpty)
    }

    @Test func aHandlerInstalledAfterTheQueueCrossedHalfIsSignalledAtOnce() {
        let sink = AppLogSink(byteLimit: 2_000)
        for index in 0..<12 { sink.append(logRecord("record \(index)")) }
        let signals = Mutex(0)
        sink.setHighWaterHandler { signals.withLock { $0 += 1 } }
        #expect(signals.withLock { $0 } == 1)
    }

    @Test func anOverlappingDrainPersistsNewRecordsBeforeJoiningTheUpload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = AppLogSink()
        let upload = UploadGate()
        let outbox = DiagnosticsOutbox(directory: directory, logSink: sink, deviceLabel: { "test-device" })
        await outbox.setDestination(upload.destination)
        sink.append(logRecord("first"))
        let first = Task { await outbox.drain(reason: "interval") }
        await upload.firstRequest()
        sink.append(logRecord("second"))
        let second = Task { await outbox.drain(reason: "highWater") }
        var persisted = false
        for _ in 0..<200 where !persisted {
            persisted = try logMessages(in: directory).contains("second")
            if !persisted { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(persisted)
        upload.open()
        await first.value
        await second.value
    }

    @Test func stoppingWaitsForTheRunningDrain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = AppLogSink()
        let upload = UploadGate()
        let outbox = DiagnosticsOutbox(directory: directory, logSink: sink, deviceLabel: { "test-device" })
        await outbox.setDestination(upload.destination)
        sink.append(logRecord("first"))
        let drain = Task { await outbox.drain(reason: "interval") }
        await upload.firstRequest()
        let stopped = Mutex(false)
        let stop = Task {
            await outbox.stopPumping()
            stopped.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!stopped.withLock { $0 })
        upload.open()
        await stop.value
        #expect(stopped.withLock { $0 })
        await drain.value
    }

    @Test func crossingHalfTheBudgetSignalsOnceUntilTheNextTake() {
        let sink = AppLogSink(byteLimit: 2_000)
        let signals = Mutex(0)
        sink.setHighWaterHandler { signals.withLock { $0 += 1 } }
        for index in 0..<12 { sink.append(logRecord("record \(index)")) }
        #expect(signals.withLock { $0 } == 1)
        let batch = sink.take()
        sink.restore(batch.records)
        sink.append(logRecord("after a failed write"))
        #expect(signals.withLock { $0 } == 1)
        _ = sink.take()
        for index in 0..<12 { sink.append(logRecord("record \(index)")) }
        #expect(signals.withLock { $0 } == 2)
    }

    @Test func aFullBufferKeepsTheNewestRecordsAndReportsTheLoss() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = DiagnosticsOutbox(directory: directory, logSink: AppLogSink(), deviceLabel: { "test-device" })
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
        let outbox = DiagnosticsOutbox(directory: directory, storedByteLimit: 4_000, logSink: AppLogSink(), deviceLabel: { "test-device" })
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

private final class UploadGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let requests = AsyncStream.makeStream(of: Void.self)

    var destination: DiagnosticsDestination {
        let host = GatewayHostConfiguration(id: UUID(), name: "Fixture", hostname: "diagnostics.test", port: 8787,
                                            authToken: "fixture-token")
        return DiagnosticsDestination(host: host) { [self] request in
            requests.continuation.yield()
            await waitUntilOpen()
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }
    }

    func firstRequest() async {
        var iterator = requests.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func waitUntilOpen() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
