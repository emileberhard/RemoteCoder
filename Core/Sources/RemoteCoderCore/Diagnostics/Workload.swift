import Foundation
import Synchronization

struct Workload: Sendable, Equatable, Encodable {
    let runningTurnNanoseconds: UInt64?
    let streamedDeltas: UInt64
    let streamedBytes: UInt64

    private enum CodingKeys: String, CodingKey {
        case runningTurnNanoseconds = "runningTurnNs", streamedDeltas, streamedBytes
    }
}

struct RunningTurnIntegral: Sendable {
    private(set) var current: Int?
    private(set) var nanoseconds: UInt64 = 0
    private var since: ContinuousClock.Instant?

    mutating func set(_ turns: Int, at now: ContinuousClock.Instant) {
        accrue(to: now)
        current = turns
    }

    mutating func accrue(to now: ContinuousClock.Instant) {
        if let current, let since {
            nanoseconds &+= UInt64(current) &* since.duration(to: now).clampedNanoseconds
        }
        since = now
    }
}

final class StreamedTextMetrics: Sendable {
    static let shared = StreamedTextMetrics()

    private let deltas = Atomic<UInt64>(0)
    private let bytes = Atomic<UInt64>(0)

    func record(_ text: String) {
        deltas.wrappingAdd(1, ordering: .relaxed)
        bytes.wrappingAdd(UInt64(text.utf8.count), ordering: .relaxed)
    }

    func snapshot() -> (deltas: UInt64, bytes: UInt64) {
        (deltas.load(ordering: .relaxed), bytes.load(ordering: .relaxed))
    }
}
