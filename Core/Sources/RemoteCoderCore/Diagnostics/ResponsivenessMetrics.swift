import CoreFoundation
import Darwin
import Foundation

@MainActor
final class ResponsivenessMetrics {
    static let shared = ResponsivenessMetrics()
    static let hangThreshold: UInt64 = 250_000_000
    static let hangNoticeSpacing: UInt64 = 10_000_000_000

    struct RunLoop: Sendable, Equatable, Encodable {
        static let thresholdsMilliseconds: [UInt64] = [17, 33, 50, 100, 250, 500, 1_000, 2_000]

        var busyNanoseconds: UInt64 = 0
        var busyPeriods: UInt64 = 0
        var hangNanoseconds: UInt64 = 0
        var busyPeriodsAtLeast = [UInt64](repeating: 0, count: thresholdsMilliseconds.count)

        private enum Key: String, CodingKey { case busyNs, busyPeriods, hangNs, busyPeriodsAtLeastMs }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(busyNanoseconds, forKey: .busyNs)
            try container.encode(busyPeriods, forKey: .busyPeriods)
            try container.encode(hangNanoseconds, forKey: .hangNs)
            try container.encode(Self.byBound(Self.thresholdsMilliseconds, busyPeriodsAtLeast), forKey: .busyPeriodsAtLeastMs)
        }

        fileprivate static func byBound(_ bounds: [UInt64], _ counts: [UInt64]) -> [String: UInt64] {
            Dictionary(uniqueKeysWithValues: zip(bounds.map(String.init), counts))
        }
    }

    struct Switches: Sendable, Equatable, Encodable {
        static let boundsMilliseconds: [UInt64] = [50, 100, 150, 200, 300, 500, 750, 1_000, 2_000, 4_000]

        var completed: UInt64 = 0
        var abandoned: UInt64 = 0
        var completedNanoseconds: UInt64 = 0
        var completedWithin = [UInt64](repeating: 0, count: boundsMilliseconds.count)

        private enum Key: String, CodingKey { case completed, abandoned, completedNs, completedWithinMs }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(completed, forKey: .completed)
            try container.encode(abandoned, forKey: .abandoned)
            try container.encode(completedNanoseconds, forKey: .completedNs)
            try container.encode(RunLoop.byBound(Self.boundsMilliseconds, completedWithin), forKey: .completedWithinMs)
        }
    }

    struct Snapshot: Sendable, Equatable {
        let runLoop: RunLoop
        let switches: Switches
    }

    var surface: UsageContext.Surface?
    private(set) var runLoop = RunLoop()
    private(set) var switches = Switches()
    private var busySince: UInt64?
    private var lastNotice: UInt64?
    private var suppressedNotices = 0
    private var observers: [CFRunLoopObserver] = []
    private let logger = AppLogger(category: "Responsiveness")

    var snapshot: Snapshot { Snapshot(runLoop: runLoop, switches: switches) }

    func install() {
        guard observers.isEmpty else { return }
        let wake = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue,
                                                      true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { ResponsivenessMetrics.shared.wake(at: Self.now()) }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                       true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { ResponsivenessMetrics.shared.sleep(at: Self.now()) }
        }
        guard let wake, let sleep else { return }
        for observer in [wake, sleep] { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = [wake, sleep]
    }

    func wake(at now: UInt64) {
        busySince = now
    }

    func sleep(at now: UInt64) {
        guard let busySince else { return }
        self.busySince = nil
        guard now >= busySince else { return }
        let elapsed = now - busySince
        runLoop.busyNanoseconds &+= elapsed
        runLoop.busyPeriods &+= 1
        let milliseconds = elapsed / 1_000_000
        guard milliseconds >= RunLoop.thresholdsMilliseconds[0] else { return }
        for (index, threshold) in RunLoop.thresholdsMilliseconds.enumerated() where milliseconds >= threshold {
            runLoop.busyPeriodsAtLeast[index] &+= 1
        }
        guard elapsed >= Self.hangThreshold else { return }
        runLoop.hangNanoseconds &+= elapsed
        noteHang(milliseconds: milliseconds, at: now)
    }

    func switchCompleted(after elapsed: Duration) {
        let nanoseconds = elapsed.clampedNanoseconds
        let milliseconds = nanoseconds / 1_000_000
        switches.completed &+= 1
        switches.completedNanoseconds &+= nanoseconds
        for (index, bound) in Switches.boundsMilliseconds.enumerated() where milliseconds <= bound {
            switches.completedWithin[index] &+= 1
        }
    }

    func switchAbandoned() {
        switches.abandoned &+= 1
    }

    private func noteHang(milliseconds: UInt64, at now: UInt64) {
        if let lastNotice, now - lastNotice < Self.hangNoticeSpacing {
            suppressedNotices += 1
            return
        }
        let suppressed = suppressedNotices == 0 ? "" : " suppressedSinceLast=\(suppressedNotices)"
        logger.notice("main run loop busy \(milliseconds) ms surface=\(surface?.rawValue ?? "unknown")\(suppressed)")
        lastNotice = now
        suppressedNotices = 0
    }

    private nonisolated static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}

extension Duration {
    var clampedNanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        guard seconds >= 0, attoseconds >= 0 else { return 0 }
        return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }
}
