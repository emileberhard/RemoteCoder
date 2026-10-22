import Foundation
#if RC_PERF_HARNESS
import Darwin
import OSLog
import Synchronization
#endif

/// Perf harness builds come only from `dev-tools/perf-sim`, which compiles
/// `RC_PERF_HARNESS`. They share the gateways with the primary phone, so they never
/// enroll installation credentials or push, VoIP, Live Activity or
/// live-navigation registrations there. They also stay off the direct LAN
/// route, whose local-network prompt would deactivate the app mid-measurement.
enum PerfBuild {
    struct CounterWindow: Sendable {
        enum ReportIssue: Error, Equatable {
            case counterFieldAlreadyPresent
        }

        private let start: [String: Int]
        private let end: [String: Int]

        nonisolated init(start: [String: Int], end: [String: Int]) {
            self.start = start
            self.end = end
        }

        nonisolated func report(_ fields: [String: Any]) throws -> [String: Any] {
            guard fields["counters"] == nil else { throw ReportIssue.counterFieldAlreadyPresent }
            var report = fields
            report["counters"] = end.merging(start) { end, start in end - start }
            return report
        }
    }

    struct Counters: Sendable {
        private(set) var generation: UInt64 = 0
        private(set) var values: [String: Int] = [:]

        nonisolated init() {}

        nonisolated mutating func count(_ name: String) {
            values[name, default: 0] += 1
            generation += 1
        }
    }

    struct CounterSampler: Sendable {
        private var previous: Counters

        nonisolated init(start: Counters) {
            previous = start
        }

        nonisolated mutating func tick(generation: UInt64, read: () -> Counters) -> [String: Int]? {
            guard generation != previous.generation else { return nil }
            let current = read()
            let changes = current.values.compactMap { name, value -> (String, Int)? in
                let delta = value - (previous.values[name] ?? 0)
                return delta == 0 ? nil : (name, delta)
            }
            previous = current
            guard !changes.isEmpty else { return nil }
            return Dictionary(uniqueKeysWithValues: changes)
        }
    }

    #if RC_PERF_HARNESS
    static let isHarness = true

    /// A/B switches for isolating one cost: `-rcPerfDisable <name>` launch
    /// arguments, comma separated, e.g. `growth`.
    nonisolated static let disabled = Set(
        (AppStorageScope.current.defaults.string(forKey: "rcPerfDisable") ?? "").split(separator: ",").map(String.init)
    )

    nonisolated static let mountCap = Int(AppStorageScope.current.defaults.string(forKey: "rcPerfMountCap") ?? "")

    /// Named event counts reported as deltas per measurement window.
    nonisolated static var counters: [String: Int] { counterState.withLock { $0.values } }
    nonisolated static var counterGeneration: UInt64 { counterState.withLock { $0.generation } }
    nonisolated static var counterSnapshot: Counters { counterState.withLock { $0 } }
    nonisolated static var gauges: [String: Int] { gaugeState.withLock { $0 } }
    private static let gaugeState = Mutex([String: Int]())
    private static let counterState = Mutex(Counters())

    nonisolated static func span(_ name: StaticString) -> PerfSpan {
        PerfSpan(name)
    }

    nonisolated static func uptimeNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    nonisolated static func resetSpans() {
        PerfSpanRecorder.reset()
    }

    nonisolated static func spanSnapshot() -> PerfSpanSnapshot {
        PerfSpanRecorder.snapshot()
    }

    static func isDisabled(_ name: String) -> Bool {
        disabled.contains(name)
    }

    nonisolated static func gauge(_ name: String, _ value: Int) {
        gaugeState.withLock { $0[name] = value }
    }

    nonisolated static func count(_ name: String) {
        counterState.withLock { $0.count(name) }
    }

    static func recordFrame(_ text: String) {
        PerfFrameRecorder.shared.record(text)
    }
    #else
    static let isHarness = false

    @inlinable nonisolated static func span(_ name: StaticString) -> PerfSpan { PerfSpan() }

    static func isDisabled(_ name: String) -> Bool { false }

    @inlinable nonisolated static func gauge(_ name: String, _ value: Int) {}
    @inlinable nonisolated static func count(_ name: String) {}

    static func recordFrame(_ text: String) {}
    #endif
}

#if RC_PERF_HARNESS
struct PerfSpan {
    private let name: StaticString
    private let started: UInt64
    private let isMainThread: Bool
    private let interval: OSSignpostIntervalState?

    fileprivate init(_ name: StaticString) {
        self.name = name
        isMainThread = Thread.isMainThread
        let signposter = PerfSpanRecorder.signposter
        interval = signposter.isEnabled ? signposter.beginInterval(name, id: signposter.makeSignpostID()) : nil
        started = PerfBuild.uptimeNanoseconds()
    }

    func end() {
        let ended = PerfBuild.uptimeNanoseconds()
        if let interval { PerfSpanRecorder.signposter.endInterval(name, interval) }
        PerfSpanRecorder.append(.init(name: name, startNanoseconds: started, endNanoseconds: ended,
                                      isMainThread: isMainThread))
    }
}

struct PerfSpanRecord: Sendable {
    let name: StaticString
    let startNanoseconds: UInt64
    let endNanoseconds: UInt64
    let isMainThread: Bool
}

struct PerfSpanSnapshot: Sendable {
    let records: [PerfSpanRecord]
    let overwritten: Int
    let capacity: Int
}

private enum PerfSpanRecorder {
    static let signposter: OSSignposter = {
        guard let subsystem = Bundle.main.bundleIdentifier else {
            preconditionFailure("Perf spans require the app bundle identifier")
        }
        return OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    }()

    private struct State {
        var records: [PerfSpanRecord] = []
        var next = 0
        var overwritten = 0

        init() { records.reserveCapacity(PerfSpanRecorder.capacity) }
    }

    private static let capacity = 65_536
    private static let state = Mutex(State())

    static func append(_ record: PerfSpanRecord) {
        state.withLock {
            if $0.records.count < capacity {
                $0.records.append(record)
            } else {
                $0.records[$0.next] = record
                $0.overwritten += 1
            }
            $0.next = ($0.next + 1) % capacity
        }
    }

    static func reset() {
        state.withLock {
            $0.records.removeAll(keepingCapacity: true)
            $0.next = 0
            $0.overwritten = 0
        }
    }

    static func snapshot() -> PerfSpanSnapshot {
        state.withLock { PerfSpanSnapshot(records: $0.records, overwritten: $0.overwritten, capacity: capacity) }
    }
}
#else
@usableFromInline
struct PerfSpan {
    @inlinable init() {}
    @inlinable func end() {}
}
#endif
