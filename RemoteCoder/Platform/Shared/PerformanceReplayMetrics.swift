#if RC_PERF_HARNESS
import Foundation
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
final class PerformanceReplayMetrics: NSObject {
    private let started = ContinuousClock.now
    private let startedAt = Date.now
    private let mainCPU = ProcessMetrics.mainThreadCPUSeconds()
    private let counters = PerfBuild.counters
    private var sampler: Task<Void, Never>?
    private var samples: [[String: Any]] = []
    private var activeThroughout = true
    private var conservedEnergy = false
    private var overflow = false
    private var display: [String: Any] = [:]
    private let workspace: ChatWorkspaceModel
    private var observation: Task<Void, Never>?
    private let fieldBuffer = TelemetryBuffer(runID: "offline-replay", capacity: 128)
    private var fieldSampler: ProcessResourceSampler?
    private let fieldCPU = ProcessResources.current()?.cpuNanoseconds
    private let fixtureWork: PerformanceReplayWork?
    private let fixtureCPU: UInt64?
    private var reads: [(elapsed: Double, mainCPU: Double?, fixtureCPU: Double?)] = []
    #if os(macOS)
    private weak var window: NSWindow?
    #endif

    init(workspace: ChatWorkspaceModel, fixtureWork: PerformanceReplayWork?) {
        self.workspace = workspace
        self.fixtureWork = fixtureWork
        fixtureCPU = fixtureWork?.snapshot.cpuNanoseconds
        super.init()
        #if os(iOS)
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
            display = ["width": window.bounds.width, "height": window.bounds.height,
                "scale": window.screen.scale, "maximumFramesPerSecond": window.screen.maximumFramesPerSecond,
                "contentSizeCategory": window.traitCollection.preferredContentSizeCategory.rawValue]
        }
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: UIApplication.willResignActiveNotification, object: nil)
        #else
        let window = NSApp.keyWindow
        self.window = window
        guard let window else { return }
        display = ["width": window.contentLayoutRect.width, "height": window.contentLayoutRect.height,
            "scale": window.backingScaleFactor, "maximumFramesPerSecond": window.screen?.maximumFramesPerSecond ?? 0]
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSWindow.didResignKeyNotification, object: window)
        #endif
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                drain()
            }
        }
        fieldSampler = ProcessResourceSampler(recorder: fieldBuffer, read: { [weak self] in
            guard let self, let resources = ProcessResources.current() else { return nil }
            guard reads.count < 128 else { overflow = true; return nil }
            let fixture = fixtureWork?.snapshot.cpuNanoseconds
            reads.append((started.duration(to: .now) / .seconds(1),
                ProcessMetrics.cpuMilliseconds(from: mainCPU, to: ProcessMetrics.mainThreadCPUSeconds()),
                fixtureCPU.flatMap { initial in fixture.flatMap { $0 >= initial ? Double($0 - initial) / 1_000_000 : nil } }))
            return resources
        })
        fieldSampler?.update(context())
        drain()
        observation = Task { [weak self] in
            for await context in Observations({ @MainActor [weak self] in self?.context() }) {
                guard let self, let context, !Task.isCancelled else { return }
                fieldSampler?.update(context)
            }
        }
    }

    private func context() -> UsageContext {
        #if os(iOS)
        let scene: UsageContext.Scene = switch UIApplication.shared.applicationState { case .active: .active; case .inactive: .inactive; default: .background }
        #else
        let scene: UsageContext.Scene = NSApp.isActive ? .active : .inactive
        #endif
        let window = workspace.keyWindow
        return UsageContext(scene: scene, surface: window.isHistoryDrawerOpen ? .drawer : .chat,
            turnRunningVisible: window.selectedScreen.map { $0.runningTurn != nil }, voiceCall: false,
            thermal: nil, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryPercent: nil, charging: nil, brightnessPercent: nil, network: nil, route: nil)
    }

    @objc private func resigned(_ notification: Notification) { activeThroughout = false }

    private func drain() {
        #if os(iOS)
        let active = UIApplication.shared.applicationState == .active
        #else
        let active = NSApp.isActive && window?.isKeyWindow == true && window?.occlusionState.contains(.visible) == true
        #endif
        activeThroughout = activeThroughout && active
        conservedEnergy = conservedEnergy || AppEnergyPolicy.current.conservesEnergy
        for line in fieldBuffer.take() {
            guard case .sample(let sample) = line.record, !reads.isEmpty else { overflow = true; continue }
            let read = reads.removeFirst()
            let encoded = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: sample.persistence.map { ($0.key.rawValue, $0.value) }))
            let persistence = encoded.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            samples.append(["at": read.elapsed,
                "processCPUms": fieldCPU.flatMap { sample.resources.cpuNanoseconds >= $0 ? Double(sample.resources.cpuNanoseconds - $0) / 1_000_000 : nil }.map { $0 as Any } ?? NSNull(),
                "mainThreadCPUms": read.mainCPU.map { $0 as Any } ?? NSNull(),
                "fixtureCPUms": read.fixtureCPU.map { $0 as Any } ?? NSNull(),
                "footprintMiB": Double(sample.resources.footprintBytes) / 1_048_576,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled, "active": active,
                "context": ["scene": sample.context.scene.rawValue,
                    "surface": sample.context.surface.map { $0.rawValue as Any } ?? NSNull(),
                    "turnRunningVisible": sample.context.turnRunningVisible.map { $0 as Any } ?? NSNull(),
                    "voiceCall": sample.context.voiceCall],
                "mixed": sample.mixed, "persistence": persistence ?? NSNull()])
        }
    }

    func finish() -> [String: Any] {
        NotificationCenter.default.removeObserver(self)
        observation?.cancel()
        observation = nil
        sampler?.cancel()
        sampler = nil
        fieldSampler?.finishPerformanceReplay()
        fieldSampler = nil
        drain()
        let elapsed = started.duration(to: .now) / .seconds(1)
        let info = Bundle.main.infoDictionary ?? [:]
        return ["seconds": elapsed, "startedAt": startedAt.timeIntervalSince1970,
            "endedAt": Date.now.timeIntervalSince1970, "activeThroughout": activeThroughout,
            "conservedEnergy": conservedEnergy, "telemetryOverflowed": overflow, "samples": samples,
            "processCPUms": samples.last?["processCPUms"] ?? NSNull(),
            "mainThreadCPUms": samples.last?["mainThreadCPUms"] ?? NSNull(),
            "fixtureCPUAttribution": ["cpuMs": samples.last?["fixtureCPUms"] ?? NSNull(),
                "scope": "synchronous current-thread fixture sections; excludes Network callbacks and unattributed cleanup",
                "coverage": "lowerBound", "lifetimeCalls": fixtureWork.map { $0.snapshot.calls as Any } ?? NSNull(),
                "lifetimePeakResponseBytes": fixtureWork.map { $0.snapshot.peakResponseBytes as Any } ?? NSNull()],
            "peakSampledFootprintMiB": samples.compactMap { $0["footprintMiB"] as? Double }.max().map { $0 as Any } ?? NSNull(),
            "counts": PerfBuild.counters.reduce(into: [String: Int]()) { $0[$1.key] = $1.value - counters[$1.key, default: 0] },
            "build": ["version": info["CFBundleShortVersionString"] ?? NSNull(),
                "commit": info["RemoteCoderSourceCommit"] ?? NSNull(),
                "modified": info["RemoteCoderSourceModified"] ?? NSNull()],
            "harnessSHA256": info["RemoteCoderPerfHarnessSHA256"] ?? NSNull(),
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "display": display,
            "locale": Locale.current.identifier,
            "processors": ProcessInfo.processInfo.processorCount,
            "disabled": PerfBuild.disabled.sorted(),
            "stateAggregationVersion": 2]
    }
}
#endif
