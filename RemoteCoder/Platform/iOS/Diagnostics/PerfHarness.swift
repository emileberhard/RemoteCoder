import Foundation

#if RC_PERF_HARNESS
import OSLog
import os
import QuartzCore
import Darwin
import UIKit
import SwiftUI

/// Measurement harness for performance passes. The Mac drives it through
/// `dev-tools/perf-sim`: it writes one JSON command into
/// `Library/Caches/perf/command.json` and posts the Darwin notification
/// `com.remotecoder.perf.command`. Results are appended to
/// `Library/Caches/perf/results.jsonl`.
@MainActor
final class PerfHarness {
    static let shared = PerfHarness()

    nonisolated static let commandNotification = "com.remotecoder.perf.command"
    nonisolated static let signposter = OSSignposter(subsystem: "RemoteCoder", category: "PerfHarness")

    private let logger = Logger(subsystem: "RemoteCoder", category: "PerfHarness")
    private weak var workspace: ChatWorkspaceModel?
    private var window: MeasurementWindow?
    private var windowTask: Task<Void, Never>?
    private var stagedReplay: StagedReplay?
    private var replayCounter = 0
    private var offlineRun: PerformanceReplayRun?
    private var fixtureControlConsumed = false

    private struct StagedReplay {
        let address: ConversationAddress
        let frames: [PerfReplayFrame]
    }

    static var directory: URL {
        URL.cachesDirectory.appending(path: "perf", directoryHint: .isDirectory)
    }

    func start(workspace: ChatWorkspaceModel) {
        guard self.workspace == nil else { return }
        self.workspace = workspace
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in Task { @MainActor in PerfHarness.shared.receiveCommand() } },
            Self.commandNotification as CFString, nil, .deliverImmediately
        )
        UIApplication.shared.isIdleTimerDisabled = true
        logger.notice("perf harness ready directory=\(Self.directory.path)")
    }

    private func receiveCommand() {
        let url = Self.directory.appending(path: "command.json")
        guard let data = try? Data(contentsOf: url),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = command["cmd"] as? String else {
            logger.error("perf command unreadable")
            return
        }
        let id = command["id"] as? String ?? UUID().uuidString
        logger.notice("perf command id=\(id) cmd=\(name)")
        switch name {
        case "begin":
            begin(label: command["label"] as? String ?? "unnamed", commandID: id)
            writeResult(["cmd": "begin", "id": id])
        case "end":
            guard let window else {
                writeResult(["cmd": "end", "id": id, "error": "no open window"])
                return
            }
            windowTask?.cancel()
            finish(window, resultID: id, extra: [:])
        case "open":
            open(address(command), commandID: id)
        case "measure-open":
            measureOpen(
                address(command),
                tail: command["tail"] as? Double ?? 2,
                label: command["label"] as? String ?? "open",
                commandID: id
            )
        case "status":
            writeResult(["cmd": "status", "id": id, "status": status()])
        case "scroll":
            guard let model = workspace?.selectedScreen,
                  let index = command["message"] as? Int, model.messages.indices.contains(index) else {
                writeResult(["cmd": "scroll", "id": id, "error": "message index is unavailable"])
                return
            }
            let rowID = ChatStreamItem.message(model.messages[index]).id
            model.requestTranscriptRow(rowID, anchor: .center, motion: .animated)
            writeResult(["cmd": "scroll", "id": id, "row": rowID])
        case "scroll-loop":
            scrollLoop(command, commandID: id)
        case "record-start":
            PerfFrameRecorder.shared.start()
            writeResult(["cmd": "record-start", "id": id])
        case "record-stop":
            let file = command["file"] as? String ?? "recording.jsonl"
            switch PerfFrameRecorder.shared.stop(writingTo: Self.directory.appending(path: file)) {
            case .success(let count): writeResult(["cmd": "record-stop", "id": id, "frames": count, "file": file])
            case .failure(let error): writeResult(["cmd": "record-stop", "id": id, "error": String(describing: error)])
            }
        case "load":
            load(file: command["file"] as? String ?? "recording.jsonl", commandID: id)
        case "replay":
            replay(
                speed: command["speed"] as? Double ?? 1,
                tail: command["tail"] as? Double ?? 2,
                label: command["label"] as? String ?? "replay",
                commandID: id
            )
        case "scenario-load":
            windowTask?.cancel()
            windowTask = Task {
                do {
                    guard offlineRun == nil else { throw PerformanceReplayScenario.Failure.invalidScenario("fresh-launch before loading another scenario") }
                    offlineRun = try await PerformanceReplayRun.prepare(Self.directory.appending(path: "scenario.json"), workspace: workspaceForReplay())
                    writeResult(["cmd": name, "id": id])
                } catch { writeResult(["cmd": name, "id": id, "error": String(describing: error)]) }
            }
        case "scenario-run":
            guard let offlineRun else { writeResult(["cmd": name, "id": id, "error": "no scenario loaded"]); return }
            windowTask = Task {
                do {
                    var report = try await offlineRun.run()
                    report["cmd"] = "window"
                    report["id"] = id
                    writeResult(report)
                } catch { writeResult(["cmd": "window", "id": id, "error": String(describing: error)]) }
            }
        case "fixture-footprint":
            windowTask?.cancel()
            windowTask = Task {
                do {
                    guard offlineRun == nil, !fixtureControlConsumed, AppStorageScope.isOfflineReplay,
                          try workspaceForReplay().settings.hosts.isEmpty,
                          let rawMode = command["mode"] as? String,
                          let mode = PerformanceReplayFixtureControl.Mode(rawValue: rawMode) else {
                        throw PerformanceReplayScenario.Failure.invalidScenario("fixture control requires a fresh offline process and explicit mode")
                    }
                    fixtureControlConsumed = true
                    var report = try await PerformanceReplayFixtureControl.run(
                        Self.directory.appending(path: "scenario.json"), mode: mode)
                    report["cmd"] = name
                    report["id"] = id
                    writeResult(report)
                } catch { writeResult(["cmd": name, "id": id, "error": String(describing: error)]) }
            }
        case "calibration-run":
            guard let host = (command["host"] as? String).flatMap(UUID.init(uuidString:)),
                  let threads = command["threads"] as? [String] else {
                writeResult(["cmd": name, "id": id, "error": "missing live host or threads"])
                return
            }
            windowTask = Task {
                do {
                    var report = try await PerformanceReplayRun.calibrate(Self.directory.appending(path: "scenario.json"),
                        workspace: workspaceForReplay(), hostID: host, threads: threads)
                    report["cmd"] = "window"
                    report["id"] = id
                    writeResult(report)
                } catch { writeResult(["cmd": "window", "id": id, "error": String(describing: error)]) }
            }
        default:
            writeResult(["cmd": name, "id": id, "error": "unknown command"])
        }
    }

    private func workspaceForReplay() throws -> ChatWorkspaceModel {
        guard let workspace else { throw PerformanceReplayScenario.Failure.invalidScenario("workspace unavailable") }
        return workspace
    }

    private func status() -> [String: Any] {
        guard let workspace else { return [:] }
        let model = workspace.selectedScreen
        if let model { model.transcriptReadingPosition.capture(scope: model.transcriptSurfaceID) }
        let reading = model?.transcriptReadingPosition
        return [
            "hosts": workspace.settings.hosts.map { ["id": $0.id.uuidString, "name": $0.name] },
            "selectedHost": model?.hostID.uuidString ?? NSNull(),
            "selectedThread": model?.openThreadID ?? NSNull(),
            "messageCount": model.map { $0.messages.count as Any } ?? NSNull(),
            "readingRow": reading?.anchor?.rowID ?? NSNull(),
            "readingOffset": reading?.anchor.map { $0.rowOffset as Any } ?? NSNull(),
            "mountedStartRow": reading?.mountedStartRowID ?? NSNull(),
            "gauges": PerfBuild.gauges,
            "footprintMB": ProcessMetrics.megabytes(ProcessMetrics.footprint()).map { $0 as Any } ?? NSNull(),
        ]
    }

    private func address(_ command: [String: Any]) -> ConversationAddress? {
        guard let hostID = (command["host"] as? String).flatMap(UUID.init(uuidString:)),
              let thread = command["thread"] as? String else { return nil }
        return ConversationAddress(hostID: hostID, threadID: thread)
    }

    private func open(_ address: ConversationAddress?, commandID: String) {
        guard let workspace, let address else {
            writeResult(["cmd": "open", "id": commandID, "error": "missing host or thread"])
            return
        }
        workspace.selectConversation(at: address)
        Task {
            guard await loaded(address) else {
                writeResult(["cmd": "open", "id": commandID, "error": "the transcript did not load"])
                return
            }
            writeResult(["cmd": "open", "id": commandID])
        }
    }

    private func measureOpen(_ address: ConversationAddress?, tail: Double, label: String, commandID: String) {
        guard let workspace, let address else {
            writeResult(["cmd": "measure-open", "id": commandID, "error": "missing host or thread"])
            return
        }
        guard !isOpen(address) else {
            writeResult(["cmd": "measure-open", "id": commandID, "error": "the conversation is already open"])
            return
        }
        let listed = workspace.model(for: address.hostID)?.conversationList.threads.contains { $0.id == address.threadID } ?? false
        begin(label: label, commandID: commandID)
        let selected = ContinuousClock.now
        workspace.selectConversation(at: address)
        windowTask = Task {
            guard await loaded(address) else {
                guard !Task.isCancelled else { return }
                abandonWindow(commandID: commandID, error: "the transcript did not load")
                return
            }
            let loadedMs = selected.duration(to: .now) / .milliseconds(1)
            guard (try? await Task.sleep(for: .seconds(tail))) != nil else { return }
            endWindow(commandID: commandID, extra: ["loadedMs": loadedMs, "listed": listed, "thread": address.threadID])
        }
    }

    private func loaded(_ address: ConversationAddress) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !hasLoaded(address) {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(16))) != nil else { return false }
        }
        return true
    }

    private func isOpen(_ address: ConversationAddress) -> Bool {
        guard let model = workspace?.selectedScreen, model.hostID == address.hostID else { return false }
        return model.openThreadID == address.threadID
    }

    private func hasLoaded(_ address: ConversationAddress) -> Bool {
        guard isOpen(address), let model = workspace?.selectedScreen else { return false }
        return model.loadingTranscriptID == nil && model.alert?.message == nil && !model.messages.isEmpty
    }

    private func scrollLoop(_ command: [String: Any], commandID: String) {
        guard let workspace, let model = workspace.selectedScreen, let threadID = model.openThreadID,
              model.loadingTranscriptID == nil, model.alert?.message == nil,
              let indices = command["messages"] as? [Int], (1...60).contains(indices.count),
              indices.allSatisfy({ model.messages.indices.contains($0) }) else {
            writeResult(["cmd": "scroll-loop", "id": commandID, "error": "provide 1–60 available message indices"])
            return
        }
        let rowIDs = indices.map { ChatStreamItem.message(model.messages[$0]).id }
        begin(label: command["label"] as? String ?? "scroll-loop", commandID: commandID)
        windowTask = Task {
            for rowID in rowIDs {
                guard !Task.isCancelled, workspace.selectedScreen === model, model.openThreadID == threadID else {
                    abandonWindow(commandID: commandID, error: "the conversation changed")
                    return
                }
                model.requestTranscriptRow(rowID, anchor: .center, motion: .animated)
                guard (try? await Task.sleep(for: .milliseconds(1_500))) != nil else { return }
            }
            guard !Task.isCancelled, workspace.selectedScreen === model, model.openThreadID == threadID else {
                abandonWindow(commandID: commandID, error: "the conversation changed")
                return
            }
            endWindow(commandID: commandID, extra: ["scrollSteps": rowIDs.count, "thread": threadID])
        }
    }

    // MARK: Measurement windows

    private func begin(label: String, commandID: String) {
        windowTask?.cancel()
        window?.cancel()
        window = MeasurementWindow(label: label, commandID: commandID)
        logger.notice("perf window begin label=\(label)")
    }

    /// Ends a command's window only if no newer window replaced it.
    private func endWindow(commandID: String, extra: [String: Any]) {
        guard let window, window.commandID == commandID else { return }
        finish(window, resultID: commandID, extra: extra)
    }

    private func abandonWindow(commandID: String, error: String) {
        guard let window, window.commandID == commandID else { return }
        window.cancel()
        self.window = nil
        writeResult(["cmd": "window", "id": commandID, "error": error])
    }

    private func finish(_ window: MeasurementWindow, resultID: String, extra: [String: Any]) {
        self.window = nil
        var result = window.finish()
        result["id"] = resultID
        result["disabled"] = PerfBuild.disabled.sorted()
        result.merge(extra) { _, new in new }
        writeResult(result)
    }

    private func writeResult(_ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        let url = Self.directory.appending(path: "results.jsonl")
        do {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data + Data("\n".utf8))
            } else {
                try (data + Data("\n".utf8)).write(to: url)
            }
        } catch {
            logger.error("perf result not written: \(error.localizedDescription)")
        }
        logger.notice("perf result \(String(decoding: data, as: UTF8.self))")
    }

    // MARK: Replay

    private func load(file: String, commandID: String) {
        guard let model = workspace?.selectedScreen,
              let target = model.openThreadID else {
            writeResult(["cmd": "load", "id": commandID, "error": "no open conversation"])
            return
        }
        stagedReplay = nil
        replayCounter += 1
        let generation = replayCounter
        let suffix = "-perf\(Int(Date().timeIntervalSince1970))\(generation)"
        Task {
            do {
                let frames = try await PerfReplayFrame.load(Self.directory.appending(path: file), targetThread: target, suffix: suffix)
                guard generation == replayCounter else { return }
                guard frames.isEmpty == false else {
                    writeResult(["cmd": "load", "id": commandID, "error": "no frames for a turn"])
                    return
                }
                stagedReplay = StagedReplay(address: ConversationAddress(hostID: model.hostID, threadID: target), frames: frames)
                writeResult(["cmd": "load", "id": commandID, "frames": frames.count, "thread": target])
            } catch {
                writeResult(["cmd": "load", "id": commandID, "error": String(describing: error)])
            }
        }
    }

    private func replay(speed: Double, tail: Double, label: String, commandID: String) {
        guard let model = workspace?.selectedScreen,
              let target = model.openThreadID else {
            writeResult(["cmd": "replay", "id": commandID, "error": "no open conversation"])
            return
        }
        guard let staged = stagedReplay, staged.address == ConversationAddress(hostID: model.hostID, threadID: target) else {
            writeResult(["cmd": "replay", "id": commandID, "error": "no recording loaded for the open conversation"])
            return
        }
        stagedReplay = nil
        let frames = staged.frames
        let client = model.target.gatewayClient
        begin(label: label, commandID: commandID)
        windowTask = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let start = clock.now
            let bytes = frames.reduce(0) { $0 + $1.text.utf8.count }
            for frame in frames {
                try? await Task.sleep(until: start + .seconds(frame.offset / speed), clock: clock)
                guard !Task.isCancelled else { return }
                await client.perfInjectNotificationFrame(frame.text)
            }
            let streamed = start.duration(to: clock.now)
            try? await Task.sleep(for: .seconds(tail))
            await MainActor.run {
                PerfHarness.shared.endWindow(commandID: commandID, extra: [
                    "replayFrames": frames.count, "bytes": bytes, "speed": speed,
                    "streamSeconds": Double(streamed.components.seconds) + Double(streamed.components.attoseconds) / 1e18,
                    "thread": target,
                ])
            }
        }
    }
}

/// One measured scenario: display-link frame pacing on the main run loop, CPU
/// time for the process and the main thread, and the memory footprint.
@MainActor
private final class MeasurementWindow: NSObject {
    let label: String
    let commandID: String
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frames = 0
    private var activeThroughout = UIApplication.shared.applicationState == .active
    private var conservedEnergy = AppEnergyPolicy.current.conservesEnergy
    private var hitches = 0
    private var longFrames: [[String: Int]] = []
    private var omittedLongFrames = 0
    private var hitchSeconds: Double = 0
    private var longestInterval: Double = 0
    private var expectedInterval: Double = 0
    private var peakFootprint: UInt64?
    private let startFootprint: UInt64?
    private let startProcessCPU: Double?
    private let startMainCPU: Double?
    private let started = ContinuousClock.now
    private let startedAt = Date.now
    private let startCounters = PerfBuild.counters
    private let signpostState: OSSignpostIntervalState

    init(label: String, commandID: String) {
        self.label = label
        self.commandID = commandID
        startFootprint = ProcessMetrics.footprint()
        peakFootprint = startFootprint
        startProcessCPU = ProcessMetrics.processCPUSeconds()
        startMainCPU = ProcessMetrics.mainThreadCPUSeconds()
        signpostState = PerfHarness.signposter.beginInterval("PerfWindow", id: PerfHarness.signposter.makeSignpostID(), "\(label, privacy: .public)")
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive(_:)),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func resignedActive(_ notification: Notification) {
        activeThroughout = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let expected = link.targetTimestamp - link.timestamp
        if expected > 0 { expectedInterval = expected }
        if lastTimestamp > 0, expectedInterval > 0 {
            let interval = link.timestamp - lastTimestamp
            longestInterval = max(longestInterval, interval)
            if interval > 0.1 {
                if longFrames.count < 64 {
                    longFrames.append(["atMs": Int(started.duration(to: .now) / .milliseconds(1)), "ms": Int(interval * 1000)])
                } else {
                    omittedLongFrames += 1
                }
            }
            if interval > expectedInterval * 1.5 {
                hitches += 1
                hitchSeconds += interval - expectedInterval
            }
        }
        lastTimestamp = link.timestamp
        frames += 1
        if frames % 6 == 0 {
            peakFootprint = peakFootprint.flatMap { peak in ProcessMetrics.footprint().map { max(peak, $0) } }
            conservedEnergy = conservedEnergy || AppEnergyPolicy.current.conservesEnergy
        }
    }

    func cancel() {
        NotificationCenter.default.removeObserver(self)
        link?.invalidate()
        link = nil
        PerfHarness.signposter.endInterval("PerfWindow", signpostState)
    }

    func finish() -> [String: Any] {
        cancel()
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let footprint = ProcessMetrics.footprint()
        let peak = peakFootprint.flatMap { peak in footprint.map { max(peak, $0) } }
        return [
            "cmd": "window", "id": commandID, "label": label,
            "seconds": seconds,
            "startedAt": startedAt.timeIntervalSince1970,
            "endedAt": Date.now.timeIntervalSince1970,
            "frames": frames,
            "activeThroughout": activeThroughout,
            "conservedEnergy": conservedEnergy,
            "refreshHz": expectedInterval > 0 ? (1 / expectedInterval).rounded() : 0,
            "hitches": hitches,
            "hitchMs": hitchSeconds * 1000,
            "hitchMsPerSecond": seconds > 0 ? hitchSeconds * 1000 / seconds : 0,
            "longestFrameMs": longestInterval * 1000,
            "longFrames": longFrames,
            "omittedLongFrames": omittedLongFrames,
            "processCPUms": ProcessMetrics.cpuMilliseconds(from: startProcessCPU, to: ProcessMetrics.processCPUSeconds()).map { $0 as Any } ?? NSNull(),
            "mainThreadCPUms": ProcessMetrics.cpuMilliseconds(from: startMainCPU, to: ProcessMetrics.mainThreadCPUSeconds()).map { $0 as Any } ?? NSNull(),
            "footprintStartMB": ProcessMetrics.megabytes(startFootprint).map { $0 as Any } ?? NSNull(),
            "footprintEndMB": ProcessMetrics.megabytes(footprint).map { $0 as Any } ?? NSNull(),
            "footprintPeakMB": ProcessMetrics.megabytes(peak).map { $0 as Any } ?? NSNull(),
            "counts": PerfBuild.counters.reduce(into: [String: Int]()) { $0[$1.key] = $1.value - startCounters[$1.key, default: 0] },
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        ]
    }
}
#endif
