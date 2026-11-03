import CoreFoundation
import Darwin
import Foundation

@MainActor
final class ResponsivenessMetrics {
    static let shared = ResponsivenessMetrics()

    struct HistoryOpens: Sendable, Equatable, Encodable {
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
            try container.encode(MainRunLoopBusyPeriods.Counters.byBound(Self.boundsMilliseconds, completedWithin),
                                 forKey: .completedWithinMs)
        }
    }

    struct HistoryOpenStart: Sendable {
        let instant: ContinuousClock.Instant
        let backgroundEntries: UInt64
        let startedInBackground: Bool
    }

    struct Snapshot: Sendable, Equatable {
        let mainRunLoop: MainRunLoopBusyPeriods.Counters
        let historyOpens: HistoryOpens
    }

    private(set) var historyOpens = HistoryOpens()
    private var backgroundEntries: UInt64 = 0
    private var scene: UsageContext.Scene?
    private let busyPeriods = MainRunLoopBusyPeriods()

    func install() {
        busyPeriods.install()
    }

    func contextChanged(_ context: UsageContext) {
        if context.scene == .background, scene != .background { backgroundEntries &+= 1 }
        scene = context.scene
        busyPeriods.label = "scene=\(context.scene.rawValue) surface=\(context.surface?.rawValue ?? "unknown")"
    }

    func settle(at now: UInt64) -> Snapshot {
        Snapshot(mainRunLoop: busyPeriods.settle(at: now), historyOpens: historyOpens)
    }

    func historyOpenStarted(at instant: ContinuousClock.Instant) -> HistoryOpenStart {
        HistoryOpenStart(instant: instant, backgroundEntries: backgroundEntries, startedInBackground: scene == .background)
    }

    func historyOpenReachedContent(_ start: HistoryOpenStart, at instant: ContinuousClock.Instant) {
        guard !start.startedInBackground, start.backgroundEntries == backgroundEntries else {
            historyOpenAbandoned()
            return
        }
        let nanoseconds = start.instant.duration(to: instant).clampedNanoseconds
        historyOpens.completed &+= 1
        historyOpens.completedNanoseconds &+= nanoseconds
        for (index, bound) in HistoryOpens.boundsMilliseconds.enumerated() where nanoseconds <= bound * 1_000_000 {
            historyOpens.completedWithin[index] &+= 1
        }
    }

    func historyOpenAbandoned() {
        historyOpens.abandoned &+= 1
    }

    nonisolated static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}

final class MainRunLoopBusyPeriods {
    static let hangThreshold: UInt64 = 250_000_000
    static let hangNoticeSpacing: UInt64 = 10_000_000_000

    struct Counters: Sendable, Equatable, Encodable {
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

        static func byBound(_ bounds: [UInt64], _ counts: [UInt64]) -> [String: UInt64] {
            Dictionary(uniqueKeysWithValues: zip(bounds.map(String.init), counts))
        }
    }

    var label = "scene=unknown surface=unknown"
    private(set) var completed = Counters()
    private var busySince: UInt64?
    private var settled: UInt64 = 0
    private var counted = false
    private var lastNotice: UInt64?
    private var suppressedNotices = 0
    private var installed = false
    private let logger = AppLogger(category: "Responsiveness")

    @MainActor
    func install() {
        guard !installed else { return }
        var context = CFRunLoopObserverContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: Self.retainInfo, release: Self.releaseInfo,
                                               copyDescription: nil)
        guard let wake = CFRunLoopObserverCreate(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true,
                                                 CFIndex.min, Self.wakeCallout, &context),
              let sleep = CFRunLoopObserverCreate(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                  CFIndex.max, Self.sleepCallout, &context) else { return }
        for observer in [wake, sleep] { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        installed = true
    }

    func settle(at now: UInt64) -> Counters {
        if let busySince, now >= busySince, now - busySince >= Self.hangThreshold { advance(to: now - busySince) }
        return completed
    }

    func wake(at now: UInt64) {
        busySince = now
        settled = 0
        counted = false
    }

    func sleep(at now: UInt64) {
        guard let busySince else { return }
        self.busySince = nil
        guard now >= busySince else { return }
        let elapsed = now - busySince
        advance(to: elapsed)
        if elapsed >= Self.hangThreshold { noteHang(milliseconds: elapsed / 1_000_000, at: now) }
    }

    private func advance(to elapsed: UInt64) {
        guard elapsed >= settled else { return }
        if !counted {
            completed.busyPeriods &+= 1
            counted = true
        }
        completed.busyNanoseconds &+= elapsed - settled
        if elapsed >= Self.hangThreshold { completed.hangNanoseconds &+= elapsed - settled }
        for (index, threshold) in Counters.thresholdsMilliseconds.enumerated()
        where settled < threshold * 1_000_000 && elapsed >= threshold * 1_000_000 {
            completed.busyPeriodsAtLeast[index] &+= 1
        }
        settled = elapsed
    }

    private func noteHang(milliseconds: UInt64, at now: UInt64) {
        if let lastNotice, now - lastNotice < Self.hangNoticeSpacing {
            suppressedNotices += 1
            return
        }
        let suppressed = suppressedNotices == 0 ? "" : " suppressedSinceLast=\(suppressedNotices)"
        logger.notice("main run loop busy \(milliseconds) ms \(label)\(suppressed)")
        lastNotice = now
        suppressedNotices = 0
    }

    private static let retainInfo: @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer? = { info in
        guard let info else { return nil }
        _ = Unmanaged<MainRunLoopBusyPeriods>.fromOpaque(info).retain()
        return info
    }

    private static let releaseInfo: @convention(c) (UnsafeRawPointer?) -> Void = { info in
        guard let info else { return }
        Unmanaged<MainRunLoopBusyPeriods>.fromOpaque(info).release()
    }

    private static let wakeCallout: CFRunLoopObserverCallBack = { _, _, info in
        guard let info else { return }
        Unmanaged<MainRunLoopBusyPeriods>.fromOpaque(info).takeUnretainedValue().wake(at: ResponsivenessMetrics.now())
    }

    private static let sleepCallout: CFRunLoopObserverCallBack = { _, _, info in
        guard let info else { return }
        Unmanaged<MainRunLoopBusyPeriods>.fromOpaque(info).takeUnretainedValue().sleep(at: ResponsivenessMetrics.now())
    }
}

extension Duration {
    var clampedNanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        guard seconds >= 0, attoseconds >= 0 else { return 0 }
        return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }
}
