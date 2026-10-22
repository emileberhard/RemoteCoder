import Foundation
import OSLog
import Synchronization

/// Logical writes, not filesystem/SQLite amplification. No per-write log or timer.
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
    }
    private struct State {
        var counters: [Owner: Counters] = [:]
        var reportDue = false
        var reportedAt = ContinuousClock.now
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

    func snapshot() -> [Owner: Counters] { state.withLock { $0.counters } }

    /// Called by the existing log pump. Diagnostic writes alone never generate a report.
    func reportIfDue() {
        let values = state.withLock { state -> [Owner: Counters]? in
            guard state.reportDue, state.reportedAt.duration(to: .now) >= .seconds(60) else { return nil }
            state.reportDue = false
            state.reportedAt = .now
            return state.counters
        }
        guard let values else { return }
        for owner in Owner.allCases {
            guard let value = values[owner] else { continue }
            logger.notice("persistence owner=\(owner.rawValue, privacy: .public) writes=\(value.writes) bytes=\(value.bytes) skipped=\(value.skipped) failures=\(value.failures) writesWithoutByteCount=\(value.writesWithoutByteCount) milliseconds=\(value.milliseconds)")
        }
    }
}
