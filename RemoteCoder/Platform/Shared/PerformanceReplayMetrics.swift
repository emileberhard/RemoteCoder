#if RC_PERF_HARNESS
import Foundation
import QuartzCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
final class PerformanceReplayMetrics: NSObject {
    private struct Frame {
        let at: Double
        let intervalMs: Double
        let expectedMs: Double
    }
    private let started = ContinuousClock.now
    private let startedAt = Date.now
    private let cpu = ProcessMetrics.processCPUSeconds()
    private let mainCPU = ProcessMetrics.mainThreadCPUSeconds()
    private let counters = PerfBuild.counters
    private var link: CADisplayLink?
    private var lastTimestamp: Double?
    private var lastSample = -1.0
    private var intervals: [Frame] = []
    private var samples: [[String: Any]] = []
    private var activeThroughout = true
    private var conservedEnergy = false
    private var overflow = false
    private var display: [String: Any] = [:]
    #if os(macOS)
    private weak var window: NSWindow?
    #endif

    override init() {
        super.init()
        intervals.reserveCapacity(15_000)
        #if os(iOS)
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
            display = ["width": window.bounds.width, "height": window.bounds.height,
                "scale": window.screen.scale, "maximumFramesPerSecond": window.screen.maximumFramesPerSecond,
                "contentSizeCategory": window.traitCollection.preferredContentSizeCategory.rawValue]
        }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = .default
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: UIApplication.willResignActiveNotification, object: nil)
        #else
        let window = NSApp.keyWindow
        self.window = window
        guard let window else { return }
        display = ["width": window.contentLayoutRect.width, "height": window.contentLayoutRect.height,
            "scale": window.backingScaleFactor, "maximumFramesPerSecond": window.screen?.maximumFramesPerSecond ?? 0]
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSWindow.didResignKeyNotification, object: window)
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
        sample(at: 0)
    }

    @objc private func resigned(_ notification: Notification) { activeThroughout = false }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = started.duration(to: .now) / .seconds(1)
        if let lastTimestamp {
            if intervals.count < 20_000 {
                intervals.append(Frame(at: elapsed, intervalMs: (link.timestamp - lastTimestamp) * 1000,
                    expectedMs: (link.targetTimestamp - link.timestamp) * 1000))
            } else { overflow = true }
        }
        lastTimestamp = link.timestamp
        if elapsed - lastSample >= 1 { sample(at: elapsed) }
    }

    private func sample(at elapsed: Double) {
        lastSample = elapsed
        #if os(iOS)
        let active = UIApplication.shared.applicationState == .active
        #else
        let active = NSApp.isActive && window?.isKeyWindow == true && window?.occlusionState.contains(.visible) == true
        #endif
        activeThroughout = activeThroughout && active
        conservedEnergy = conservedEnergy || AppEnergyPolicy.current.conservesEnergy
        samples.append(["at": elapsed,
            "processCPUms": ProcessMetrics.cpuMilliseconds(from: cpu, to: ProcessMetrics.processCPUSeconds()).map { $0 as Any } ?? NSNull(),
            "mainThreadCPUms": ProcessMetrics.cpuMilliseconds(from: mainCPU, to: ProcessMetrics.mainThreadCPUSeconds()).map { $0 as Any } ?? NSNull(),
            "footprintMiB": ProcessMetrics.megabytes(ProcessMetrics.footprint()).map { $0 as Any } ?? NSNull(),
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled, "active": active])
    }

    func finish() -> [String: Any] {
        NotificationCenter.default.removeObserver(self)
        link?.invalidate()
        link = nil
        let elapsed = started.duration(to: .now) / .seconds(1)
        sample(at: elapsed)
        let info = Bundle.main.infoDictionary ?? [:]
        return ["seconds": elapsed, "startedAt": startedAt.timeIntervalSince1970,
            "endedAt": Date.now.timeIntervalSince1970, "activeThroughout": activeThroughout,
            "conservedEnergy": conservedEnergy, "frames": intervals.count,
            "frameIntervals": intervals.map { ["at": $0.at, "intervalMs": $0.intervalMs, "expectedMs": $0.expectedMs] },
            "frameIntervalsOverflowed": overflow, "samples": samples,
            "processCPUms": samples.last?["processCPUms"] ?? NSNull(),
            "mainThreadCPUms": samples.last?["mainThreadCPUms"] ?? NSNull(),
            "peakSampledFootprintMiB": samples.compactMap { $0["footprintMiB"] as? Double }.max().map { $0 as Any } ?? NSNull(),
            "counts": PerfBuild.counters.reduce(into: [String: Int]()) { $0[$1.key] = $1.value - counters[$1.key, default: 0] },
            "build": ["version": info["CFBundleShortVersionString"] ?? NSNull(),
                "commit": info["RemoteCoderSourceCommit"] ?? NSNull(),
                "modified": info["RemoteCoderSourceModified"] ?? NSNull()],
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "display": display,
            "locale": Locale.current.identifier,
            "processors": ProcessInfo.processInfo.processorCount,
            "disabled": PerfBuild.disabled.sorted(),
            "frameMetric": "CADisplayLink callback intervals; use Instruments Hitches for presentation hitches"]
    }
}
#endif
