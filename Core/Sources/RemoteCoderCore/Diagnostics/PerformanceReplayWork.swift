#if RC_PERF_HARNESS || SWIFT_PACKAGE
import Darwin
import Foundation
import Synchronization

nonisolated final class PerformanceReplayWork: Sendable {
    struct Snapshot: Sendable {
        var cpuNanoseconds: UInt64? = 0
        var calls = 0
        var peakResponseBytes = 0
    }

    private let counters = Mutex(Snapshot())

    var snapshot: Snapshot { counters.withLock { $0 } }

    func measure<T>(_ operation: () throws -> T) rethrows -> T {
        let start = Self.threadCPU()
        defer {
            let end = Self.threadCPU()
            counters.withLock { value in
                value.calls += 1
                if let start, let end, end >= start, let total = value.cpuNanoseconds {
                    let sum = total.addingReportingOverflow(end - start)
                    value.cpuNanoseconds = sum.overflow ? nil : sum.partialValue
                } else { value.cpuNanoseconds = nil }
            }
        }
        return try operation()
    }

    func recordResponse(bytes: Int) {
        counters.withLock { $0.peakResponseBytes = max($0.peakResponseBytes, bytes) }
    }

    private static func threadCPU() -> UInt64? {
        var value = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0, value.tv_sec >= 0, value.tv_nsec >= 0 else { return nil }
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
}
#endif
