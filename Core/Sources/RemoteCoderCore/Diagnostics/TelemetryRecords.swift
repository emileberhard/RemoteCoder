import Foundation
import Synchronization

struct UsageContext: Codable, Sendable, Equatable {
    enum Scene: String, Codable, Sendable { case active, inactive, background }
    enum Surface: String, Codable, Sendable { case chat, drawer }
    enum Route: String, Codable, Sendable { case lan, configured, relay, restarting, disconnected }
    enum Network: String, Codable, Sendable { case wifi, cellular, wired, other, none }
    enum Thermal: String, Codable, Sendable { case nominal, fair, serious, critical }

    var scene: Scene
    var surface: Surface?
    var turnRunningVisible: Bool?
    var voiceCall: Bool
    var thermal: Thermal?
    var lowPower: Bool
    var batteryPercent: Int?
    var charging: Bool?
    var brightnessPercent: Int?
    var network: Network?
    var route: Route?
}

struct ProcessSample: Sendable {
    enum Reason: String, Encodable, Sendable { case launch, interval, context, foreground, background }

    let reason: Reason
    let resources: ProcessResources
    let readNanoseconds: UInt64
    let persistence: [PersistenceMetrics.Owner: PersistenceMetrics.Counters]
    let mixed: Bool
    let context: UsageContext
}

struct ExportCost: Sendable {
    let reason: String
    var scanMilliseconds = 0.0
    var encodeMilliseconds = 0.0
    var writeMilliseconds = 0.0
    var compressMilliseconds = 0.0
    var uploadMilliseconds = 0.0
    var totalMilliseconds = 0.0
    var scanned = 0
    var kept = 0
    var segments = 0
    var bytes = 0
    var flushedRecords = 0
    var uploadedSegments = 0
    var uploadedBytes = 0
    var footprintBefore: UInt64?
    var footprintSampledMax: UInt64?
    var footprintAfter: UInt64?
    var processCPUNanoseconds: UInt64?
}

struct TelemetryLoss: Sendable {
    enum What: String, Encodable, Sendable { case telemetryRecords, logSegment, telemetrySegment, metricKitSegment }

    let what: What
    let count: Int
    let bytes: Int?
    let reason: String
}

enum TelemetryRecord: Sendable {
    case sample(ProcessSample)
    case export(ExportCost)
    case loss(TelemetryLoss)
}

struct TelemetryRun: Encodable, Sendable {
    static let schemaVersion = 1

    let runID: String
    var installationID: String?
    let model: String?
    let simulator: Bool
    let appVersion: String?
    let sourceCommit: String?
    let build: String?
    let osVersion: String
    let osBuild: String?
    let startedAt: Date
    let startedMonoNs: UInt64

    static func make(installationID: String?, bundle: Bundle = .main) -> TelemetryRun {
        #if targetEnvironment(simulator)
        let simulator = true
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        #elseif os(macOS)
        let simulator = false
        let model = sysctlString("hw.model")
        #else
        let simulator = false
        let model = sysctlString("hw.machine")
        #endif
        return TelemetryRun(
            runID: UUID().uuidString.lowercased(),
            installationID: installationID,
            model: model,
            simulator: simulator,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            sourceCommit: BuildIdentity(info: bundle.infoDictionary ?? [:]).commit,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            osBuild: sysctlString("kern.osversion"),
            startedAt: .now,
            startedMonoNs: MachTime.continuousNanoseconds()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

struct TelemetryLine: Encodable, Sendable {
    let runID: String
    let seq: UInt64
    let at: Date
    let monoNs: UInt64
    let record: TelemetryRecord

    private enum Key: String, CodingKey {
        case recordType, schemaVersion, runID, seq, ts, monoNs, reason
        case cpuUserNs, cpuSystemNs, gpuNs, interruptWakeups, idleWakeups, timerWakeups, footprintBytes, readNs
        case persistence, mixed, context
        case scanMs, encodeMs, writeMs, compressMs, uploadMs, totalMs, scanned, kept, segments, bytes
        case flushedRecords, uploadedSegments, uploadedBytes, footprintBefore, footprintSampledMax, footprintAfter
        case processCpuNs
        case what, count
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(TelemetryRun.schemaVersion, forKey: .schemaVersion)
        try container.encode(runID, forKey: .runID)
        try container.encode(seq, forKey: .seq)
        try container.encode(at, forKey: .ts)
        try container.encode(monoNs, forKey: .monoNs)
        switch record {
        case .sample(let sample):
            try container.encode("sample", forKey: .recordType)
            try container.encode(sample.reason, forKey: .reason)
            let resources = sample.resources
            try container.encode(resources.cpuUserNanoseconds, forKey: .cpuUserNs)
            try container.encode(resources.cpuSystemNanoseconds, forKey: .cpuSystemNs)
            try container.encode(resources.gpuNanoseconds, forKey: .gpuNs)
            try container.encode(resources.interruptWakeups, forKey: .interruptWakeups)
            try container.encode(resources.idleWakeups, forKey: .idleWakeups)
            try container.encode(resources.timerWakeups, forKey: .timerWakeups)
            try container.encode(resources.footprintBytes, forKey: .footprintBytes)
            try container.encode(sample.readNanoseconds, forKey: .readNs)
            try container.encode(Dictionary(uniqueKeysWithValues: sample.persistence.map { ($0.key.rawValue, $0.value) }),
                                 forKey: .persistence)
            try container.encode(sample.mixed, forKey: .mixed)
            try container.encode(sample.context, forKey: .context)
        case .export(let cost):
            try container.encode("export", forKey: .recordType)
            try container.encode(cost.reason, forKey: .reason)
            try container.encode(cost.scanMilliseconds, forKey: .scanMs)
            try container.encode(cost.encodeMilliseconds, forKey: .encodeMs)
            try container.encode(cost.writeMilliseconds, forKey: .writeMs)
            try container.encode(cost.compressMilliseconds, forKey: .compressMs)
            try container.encode(cost.uploadMilliseconds, forKey: .uploadMs)
            try container.encode(cost.totalMilliseconds, forKey: .totalMs)
            try container.encode(cost.scanned, forKey: .scanned)
            try container.encode(cost.kept, forKey: .kept)
            try container.encode(cost.segments, forKey: .segments)
            try container.encode(cost.bytes, forKey: .bytes)
            try container.encode(cost.flushedRecords, forKey: .flushedRecords)
            try container.encode(cost.uploadedSegments, forKey: .uploadedSegments)
            try container.encode(cost.uploadedBytes, forKey: .uploadedBytes)
            try container.encodeIfPresent(cost.footprintBefore, forKey: .footprintBefore)
            try container.encodeIfPresent(cost.footprintSampledMax, forKey: .footprintSampledMax)
            try container.encodeIfPresent(cost.footprintAfter, forKey: .footprintAfter)
            try container.encodeIfPresent(cost.processCPUNanoseconds, forKey: .processCpuNs)
        case .loss(let loss):
            try container.encode("loss", forKey: .recordType)
            try container.encode(loss.what, forKey: .what)
            try container.encode(loss.count, forKey: .count)
            try container.encodeIfPresent(loss.bytes, forKey: .bytes)
            try container.encode(loss.reason, forKey: .reason)
        }
    }
}

struct TelemetryRunHeader: Encodable, Sendable {
    let run: TelemetryRun
    let flushedThroughSeq: UInt64

    private enum Key: String, CodingKey { case recordType, schemaVersion, flushedThroughSeq }

    func encode(to encoder: any Encoder) throws {
        try run.encode(to: encoder)
        var container = encoder.container(keyedBy: Key.self)
        try container.encode("run", forKey: .recordType)
        try container.encode(TelemetryRun.schemaVersion, forKey: .schemaVersion)
        try container.encode(flushedThroughSeq, forKey: .flushedThroughSeq)
    }
}

final class TelemetryBuffer: Sendable {
    private struct State {
        var lines: [TelemetryLine] = []
        var nextSeq: UInt64 = 1
        var dropped = 0
    }

    let runID: String
    private let capacity: Int
    private let state = Mutex(State())

    init(runID: String, capacity: Int = 256) {
        self.runID = runID
        self.capacity = capacity
    }

    func record(_ record: TelemetryRecord) {
        let at = Date.now
        let monoNs = MachTime.continuousNanoseconds()
        state.withLock { state in
            if state.lines.count >= capacity {
                state.lines.removeFirst()
                state.dropped += 1
            }
            state.lines.append(TelemetryLine(runID: runID, seq: state.nextSeq, at: at, monoNs: monoNs, record: record))
            state.nextSeq += 1
        }
    }

    func take() -> [TelemetryLine] {
        let at = Date.now
        let monoNs = MachTime.continuousNanoseconds()
        return state.withLock { state in
            var lines = state.lines
            if state.dropped > 0 {
                lines.append(TelemetryLine(runID: runID, seq: state.nextSeq, at: at, monoNs: monoNs, record: .loss(
                    TelemetryLoss(what: .telemetryRecords, count: state.dropped, bytes: nil, reason: "memory buffer full"))))
                state.nextSeq += 1
                state.dropped = 0
            }
            state.lines.removeAll(keepingCapacity: true)
            return lines
        }
    }

    func restore(_ lines: [TelemetryLine]) {
        state.withLock { state in
            let merged = lines + state.lines
            let overflow = max(0, merged.count - capacity)
            state.lines = Array(merged.dropFirst(overflow))
            state.dropped += overflow
        }
    }
}
