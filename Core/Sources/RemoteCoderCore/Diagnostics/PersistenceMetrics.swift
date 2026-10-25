import Foundation
import OSLog
import Synchronization

/// Logical writes, not filesystem/SQLite amplification. No per-write log or scheduled timer.
final class PersistenceMetrics: Sendable {
    static let shared = PersistenceMetrics()
    enum Owner: String, Sendable, CaseIterable, Codable {
        case historyPages, threadHeaders, checkpoints, drafts, diagnostics
    }
    struct Counters: Sendable, Codable, Equatable {
        var writes = 0
        var bytes = 0
        var writesWithoutByteCount = 0
        var skipped = 0
        var failures = 0
        var milliseconds = 0.0
        var checkpoint: CheckpointCounters?
    }
    enum CheckpointPhase: String, Sendable, CaseIterable {
        case total, preflight, predecessorWait, encodeWait, encodeQueue, encodeRun, encodeResume
        case admission, database, chunking, sqlCommit, finalize, historyShedRead
    }
    struct PhaseCounters: Sendable, Codable, Equatable {
        let count: Int
        let milliseconds: Double
        let p50UpperBoundMilliseconds: Double
        let maxMilliseconds: Double
    }
    struct CheckpointCounters: Sendable, Codable, Equatable {
        let writes: Int
        let inputBytes: Int
        let newPayloadBytes: Int
        let phases: [String: PhaseCounters]
    }
    struct CheckpointSave {
        private let metrics: PersistenceMetrics
        private let started: ContinuousClock.Instant
        private var phaseStarted: ContinuousClock.Instant
        private var phase = CheckpointPhase.preflight

        fileprivate init(metrics: PersistenceMetrics) {
            self.metrics = metrics
            started = .now
            phaseStarted = started
        }

        mutating func advance(to next: CheckpointPhase) {
            let now = ContinuousClock.now
            metrics.recordCheckpointPhase(phase, elapsed: phaseStarted.duration(to: now))
            phase = next
            phaseStarted = now
        }

        func finish() {
            let now = ContinuousClock.now
            metrics.recordCheckpointPhase(phase, elapsed: phaseStarted.duration(to: now))
            metrics.recordCheckpointPhase(.total, elapsed: started.duration(to: now))
        }
    }
    private struct Timing {
        private static let bounds = (0..<64).map { 0.001 * pow(2, Double($0) / 2) }
        private var buckets = [Int](repeating: 0, count: 64)
        private var count = 0
        private var milliseconds = 0.0
        private var maximum = 0.0

        mutating func record(_ elapsed: Duration) {
            let components = elapsed.components
            let value = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
            count += 1
            milliseconds += value
            maximum = max(maximum, value)
            var low = 0
            var high = buckets.count - 1
            while low < high {
                let middle = (low + high) / 2
                if value <= Self.bounds[middle] { high = middle }
                else { low = middle + 1 }
            }
            buckets[low] += 1
        }

        var counters: PhaseCounters {
            let halfway = (count + 1) / 2
            var seen = 0
            for (index, count) in buckets.enumerated() {
                seen += count
                if seen >= halfway {
                    let bound = index == buckets.count - 1 ? maximum : Self.bounds[index]
                    return PhaseCounters(count: self.count, milliseconds: milliseconds,
                        p50UpperBoundMilliseconds: min(bound, maximum), maxMilliseconds: maximum)
                }
            }
            preconditionFailure("A recorded timing has no histogram samples")
        }
    }
    private struct State {
        var counters: [Owner: Counters] = [:]
        var checkpointPhases: [CheckpointPhase: Timing] = [:]
        var checkpointWrites = 0
        var checkpointInputBytes = 0
        var checkpointNewPayloadBytes = 0
        var reportDue = false
        var reportedAt = ContinuousClock.now

        func snapshot() -> [Owner: Counters] {
            var result = counters
            if !checkpointPhases.isEmpty {
                result[.checkpoints, default: Counters()].checkpoint = CheckpointCounters(
                    writes: checkpointWrites, inputBytes: checkpointInputBytes, newPayloadBytes: checkpointNewPayloadBytes,
                    phases: Dictionary(uniqueKeysWithValues: checkpointPhases.map { ($0.key.rawValue, $0.value.counters) }))
            }
            return result
        }
    }
    private let state = Mutex(State())
    private let logger = Logger(subsystem: "RemoteCoder", category: "PersistenceMetrics")

    func wrote(_ owner: Owner, bytes: Int?, elapsed: Duration) {
        let components = elapsed.components
        state.withLock {
            $0.counters[owner, default: Counters()].writes += 1
            $0.counters[owner, default: Counters()].bytes += bytes ?? 0
            if bytes == nil { $0.counters[owner, default: Counters()].writesWithoutByteCount += 1 }
            $0.counters[owner, default: Counters()].milliseconds +=
                Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
            if owner != .diagnostics { $0.reportDue = true }
        }
    }

    func skipped(_ owner: Owner) {
        state.withLock {
            $0.counters[owner, default: Counters()].skipped += 1
            if owner != .diagnostics { $0.reportDue = true }
        }
    }

    func failed(_ owner: Owner) {
        state.withLock {
            $0.counters[owner, default: Counters()].failures += 1
            if owner != .diagnostics { $0.reportDue = true }
        }
    }

    func beginCheckpointSave() -> CheckpointSave { CheckpointSave(metrics: self) }

    func recordCheckpointPhase(_ phase: CheckpointPhase, elapsed: Duration) {
        state.withLock {
            $0.checkpointPhases[phase, default: Timing()].record(elapsed)
            $0.reportDue = true
        }
    }

    func recordCheckpointWrite(inputBytes: Int, newPayloadBytes: Int, chunking: Duration, sqlCommit: Duration) {
        state.withLock {
            $0.checkpointWrites += 1
            $0.checkpointInputBytes += inputBytes
            $0.checkpointNewPayloadBytes += newPayloadBytes
            $0.checkpointPhases[.chunking, default: Timing()].record(chunking)
            $0.checkpointPhases[.sqlCommit, default: Timing()].record(sqlCommit)
            $0.reportDue = true
        }
    }

    func snapshot() -> [Owner: Counters] { state.withLock { $0.snapshot() } }

    /// Called by the existing log pump. Diagnostic writes alone never generate a report.
    func reportIfDue() {
        let values = state.withLock { state -> [Owner: Counters]? in
            guard state.reportDue, state.reportedAt.duration(to: .now) >= .seconds(60) else { return nil }
            state.reportDue = false
            state.reportedAt = .now
            return state.snapshot()
        }
        guard let values else { return }
        for owner in Owner.allCases {
            guard let value = values[owner] else { continue }
            logger.notice("persistence owner=\(owner.rawValue, privacy: .public) writes=\(value.writes) bytes=\(value.bytes) skipped=\(value.skipped) failures=\(value.failures) writesWithoutByteCount=\(value.writesWithoutByteCount) milliseconds=\(value.milliseconds)")
        }
    }
}
