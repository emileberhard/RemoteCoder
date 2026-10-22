#if RC_PERF_HARNESS
import AppKit
import AVFoundation
import OSLog
import QuartzCore
import ScreenCaptureKit
import SwiftUI
import Synchronization

/// Mac scroll bench for performance passes, driven by `dev-tools/mac-bench`.
/// The plan arrives as the `-rcPerfBench <json>` launch argument; the report and
/// optional window recording are written to the benchmark scope's temporary cache
/// and the run's directory is printed as one JSON line on standard output.
@MainActor
final class PerfHarness {
    static let shared = PerfHarness()

    private let logger = Logger(subsystem: "RemoteCoder", category: "PerfHarness")
    private weak var workspace: ChatWorkspaceModel?
    private var bench: Task<Void, Never>?
    private var configurationError: String?

    static func hostStore(defaults: UserDefaults) -> HostStore {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-rcPerfBench") else { return HostStore(defaults: defaults) }
        let credentials = BenchGatewayCredentials()
        do {
            try BenchPlan.validateLaunch(arguments)
            guard arguments.indices.contains(flag + 1) else { throw BenchFailure("benchmark plan is missing") }
            let plan = try JSONDecoder().decode(BenchPlan.self, from: Data(arguments[flag + 1].utf8))
            try plan.validate()
            let configuration = try LocalConfiguration.load(bundle: .main)
            let host = try GatewayHostConfiguration.macBookSeed(matching: plan.host, from: configuration)
            let store = HostStore(hosts: [host], activeHostID: host.id, defaults: defaults, credentials: credentials)
            if let error = store.errorMessage { throw BenchFailure(error) }
            return store
        } catch {
            shared.configurationError = error.localizedDescription
            return HostStore(hosts: [], activeHostID: nil, defaults: defaults, credentials: credentials)
        }
    }

    fileprivate var firstReadyEvents: [String: (time: Double, mainCPU: Double?, counters: [String: Int],
        hosts: AppKitTranscriptContainer.HostWorkForBench, reading: [String: Any])] = [:]

    func contentBecameReady(at address: ConversationAddress, container: AppKitTranscriptContainer) {
        guard let workspace, workspace.isShowingConversation(at: address, on: workspace.selectedScreen),
              let fixture = workspace.selectedScreen?.target.switchFixtures[address.threadID],
              firstReadyEvents[address.threadID] == nil else { return }
        firstReadyEvents[address.threadID] = (CACurrentMediaTime(), ProcessMetrics.mainThreadCPUSeconds(),
            PerfBuild.counters, container.hostWorkForBench(),
            ["state": container.readingStateForBench(), "bookmark": Self.readingBookmark(fixture.session.readingPosition),
             "fixtureOwnsReading": container.hasReadingOwnerForBench(fixture.session.readingPosition)])
    }

    func resetFirstReady(threadID: String) { firstReadyEvents.removeValue(forKey: threadID) }

    static var directory: URL {
        AppStorageScope.current.caches.appending(path: "perf", directoryHint: .isDirectory)
    }

    func start(workspace: ChatWorkspaceModel) {
        guard self.workspace == nil else { return }
        self.workspace = workspace
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-rcPerfOffline") {
            guard let flag = arguments.firstIndex(of: "-rcPerfScenario"), arguments.indices.contains(flag + 1),
                  let out = arguments.firstIndex(of: "-rcPerfOutput"), arguments.indices.contains(out + 1) else {
                Self.emit(["error": "offline replay requires -rcPerfScenario and -rcPerfOutput"])
                return
            }
            bench = Task {
                do {
                    let run = try await PerformanceReplayRun.prepare(URL(filePath: arguments[flag + 1]), workspace: workspace)
                    let report = try await run.run()
                    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: URL(filePath: arguments[out + 1]))
                    Self.emit(["replay": "done", "valid": report["valid"] ?? false])
                } catch { Self.emit(["error": String(describing: error)]) }
                NSApp.terminate(nil)
            }
            return
        }
        if let configurationError {
            Self.emit(["error": "benchmark configuration: \(configurationError)"])
            NSApp.terminate(nil)
            return
        }
        guard let flag = arguments.firstIndex(of: "-rcPerfBench"), arguments.indices.contains(flag + 1) else { return }
        let json = arguments[flag + 1]
        logger.notice("perf bench plan received bytes=\(json.utf8.count, privacy: .public)")
        bench = Task { await run(json, workspace: workspace) }
    }

    private func run(_ json: String, workspace: ChatWorkspaceModel) async {
        let plan: BenchPlan
        do {
            plan = try JSONDecoder().decode(BenchPlan.self, from: Data(json.utf8))
            try plan.validate()
        } catch {
            Self.emit(["error": "invalid plan: \(error)"])
            NSApp.terminate(nil)
            return
        }
        if let appearance = plan.appearance {
            NSApp.appearance = NSAppearance(named: appearance == .light ? .aqua : .darkAqua)
        }
        let output = Self.directory.appending(path: "bench/\(plan.label)", directoryHint: .isDirectory)
        var report: [String: Any]
        do {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            report = try await ScrollBench(plan: plan, workspace: workspace, output: output).run()
        } catch {
            report = ["error": String(describing: error)]
        }
        report["label"] = plan.label
        report["delivery"] = plan.delivery.rawValue
        let info = Bundle.main.infoDictionary ?? [:]
        report["build"] = [
            "version": info["CFBundleShortVersionString"] ?? NSNull(),
            "build": info["CFBundleVersion"] ?? NSNull(),
            "commit": info["RemoteCoderSourceCommit"] ?? NSNull(),
            "modified": info["RemoteCoderSourceModified"] ?? NSNull(),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try data.write(to: output.appending(path: "report.json"))
            Self.emit(["bench": "done", "dir": output.path, "error": report["error"] ?? NSNull()])
        } catch {
            Self.emit(["error": "report not written: \(error)"])
        }
        logger.notice("perf bench finished label=\(plan.label, privacy: .public)")
        if plan.quit { NSApp.terminate(nil) }
    }

    fileprivate static func readingBookmark(_ position: TranscriptReadingPosition) -> [String: Any] {
        let anchor = position.anchor.map { anchor -> [String: Any] in
            ["rowID": anchor.rowID, "offset": anchor.rowOffset, "fraction": anchor.rowFraction,
             "height": anchor.rowHeight, "viewportHeight": anchor.viewportHeight,
             "viewportFraction": anchor.viewportFraction,
             "layout": anchor.layout.map { layout -> Any in
                 ["columnWidth": layout.columnWidth, "scale": layout.interfaceScale,
                  "dynamicTypeSize": layout.dynamicTypeSize, "locale": layout.localeIdentifier,
                  "rightToLeft": layout.isRightToLeft] as [String: Any]
             } ?? NSNull()]
        }
        return ["following": position.isFollowingLatest, "anchor": anchor.map { $0 as Any } ?? NSNull(),
                "lastRestorationRowID": position.lastRestorationOutcome.map { $0.rowID as Any } ?? NSNull(),
                "lastRestorationOutcome": position.lastRestorationOutcome.map { $0.outcome.rawValue as Any } ?? NSNull()]
    }

    fileprivate static func emit(_ line: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

nonisolated private final class BenchGatewayCredentials: GatewayCredentialStorage {
    private let data = Mutex<Data?>(nil)
    func read() -> Data? { data.withLock { $0 } }
    func write(_ data: Data) { self.data.withLock { $0 = data } }
}

struct SwitchFixture: Sendable {
    let header: ConversationHeader
    let session: ConversationSession

    @concurrent static func event(_ method: String, params: [String: JSONValue]) async throws -> TurnScopedGatewayEvent {
        let params = JSONValue.object(params)
        let note = CodexGatewayNotification(method: method, params: params,
            server: ServerNotification.decode(method: method, params: params), receivedAt: Date())
        guard case .turnEvent(let event) = GatewayNotificationRouting.route(note) else {
            throw BenchFailure("invalid switch streaming fixture event")
        }
        return event
    }

    @concurrent static func make(name: String, messages: Int, directory: URL) async throws -> SwitchFixture {
        let threadID = "claude_rc-switch-\(name)"
        let id = ChatMessage.deterministicID(for: threadID)
        let store = ConversationCheckpointStore(hostID: UUID(), directory: directory, primaryBudgetBytes: 512 * 1_024 * 1_024)
        var state = ConversationState(conversationID: id, threadID: threadID)
        var entries: [HistoryWindow.Entry] = []
        for index in 0..<messages {
            let turnID = "turn-\(index)"
            let itemID = "message-\(index)"
            let passage = "Conversation \(name), message \(index). Prepared history keeps its meaning while the reader switches between conversations. "
            let text = "## \(name.uppercased()) · \(index)\n\n" + String(repeating: passage + "\n\n", count: index == messages - 1 ? 8 : 3)
            var turn = ConversationState.Turn(id: turnID)
            turn.order = [itemID]
            turn.items[itemID] = .init(value: .agentMessage(id: itemID, text: text), completed: true, detailed: true)
            turn.terminal = true
            turn.terminalStatus = .completed
            state.order.append(turnID)
            state.turns[turnID] = turn
            entries.append(.init(turnId: turnID, item: .agentMessage(id: itemID, text: text), isComplete: true))
        }
        var window = HistoryWindow()
        window.apply(.init(items: .init(elements: entries, older: nil, newer: nil, fetchedAt: .distantPast),
                           placement: .reset, metadata: []))
        state.window = window
        state.markPersistedChange()
        try await store.save(state.checkpoint, conversationID: id)
        let session = ConversationSession(conversationID: id, threadID: threadID, checkpoints: store,
            checkpointGeneration: await store.generation(for: id))
        let header = ConversationHeader(.init(id: threadID, preview: name, createdAt: 1, updatedAt: 1,
            path: nil, cwd: "", source: .string("cli"), name: name, status: .idle))
        return SwitchFixture(header: header, session: session)
    }
}

private struct BenchFailure: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
    init(_ description: String) { self.description = description }
}

@MainActor
private final class BenchmarkWindowObservation: NSObject {
    private let window: NSWindow
    private var failure: BenchFailure?

    init(window: NSWindow) {
        self.window = window
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(resigned(_:)), name: NSApplication.didResignActiveNotification, object: NSApp)
        center.addObserver(self, selector: #selector(resigned(_:)), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    func validate() throws {
        if failure == nil {
            if !NSApp.isActive { failure = BenchFailure("benchmark app became inactive") }
            else if !window.isKeyWindow { failure = BenchFailure("benchmark window lost key status") }
            else if !window.occlusionState.contains(.visible) { failure = BenchFailure("benchmark window became occluded") }
        }
        if let failure { throw failure }
    }

    @objc private func resigned(_ notification: Notification) {
        guard failure == nil else { return }
        failure = BenchFailure(notification.name == NSApplication.didResignActiveNotification
            ? "benchmark app became inactive" : "benchmark window lost key status")
    }

    @objc private func occlusionChanged() {
        guard failure == nil, !window.occlusionState.contains(.visible) else { return }
        failure = BenchFailure("benchmark window became occluded")
    }
}

@MainActor
fileprivate final class ScrollBench {
    private let logger = Logger(subsystem: "RemoteCoder", category: "PerfHarness")
    let plan: BenchPlan
    let workspace: ChatWorkspaceModel
    let output: URL
    private var overflowRowID: String?

    private enum SwitchReturnPosition {
        case latest
        case reading(rowID: String, offset: CGFloat)

        var mode: String {
            switch self {
            case .latest: "latest"
            case .reading: "reading"
            }
        }

        func isPreserved(in snapshot: AppKitTranscriptContainer.HostWorkForBench, tolerance: CGFloat) -> Bool {
            switch self {
            case .latest:
                snapshot.followingLatest && abs(snapshot.latestDistance) <= tolerance
            case .reading(let rowID, let offset):
                !snapshot.followingLatest && snapshot.readingPoint.map {
                    $0.rowID == rowID && abs($0.offset - offset) <= tolerance
                } == true
            }
        }
    }

    private struct SwitchReturnState {
        let position: SwitchReturnPosition
        let hosts: AppKitTranscriptContainer.HostWorkForBench
    }

    private func verifiedNewHosts(from before: AppKitTranscriptContainer.HostWorkForBench,
                                  to after: AppKitTranscriptContainer.HostWorkForBench,
                                  countsBefore: [String: Int], countsAfter: [String: Int]) -> [String]? {
        guard !before.rows.isEmpty else { return nil }
        for (id, old) in before.rows {
            guard let current = after.rows[id], old.view != nil, old.view === current.view,
                  old.rootRevision == current.rootRevision,
                  old.measureRequests == current.measureRequests,
                  old.measurement == current.measurement,
                  old.acceptedMeasurementChanges == current.acceptedMeasurementChanges else { return nil }
        }
        let added = after.rows.keys.filter { before.rows[$0] == nil }.sorted()
        let originalPreparation = before.viewport.insetBy(dx: 0, dy: -before.viewport.height)
        let finalPreparation = after.viewport.insetBy(dx: 0, dy: -after.viewport.height)
        var originalPreparationInFinal = originalPreparation
        if !added.isEmpty {
            guard before.followingLatest == after.followingLatest,
                  let originalOwner = before.positionOwnerY, let finalOwner = after.positionOwnerY else { return nil }
            originalPreparationInFinal = originalPreparation.offsetBy(dx: 0, dy: finalOwner - originalOwner)
        }
        for id in added {
            guard let host = after.rows[id], host.view != nil, host.rootRevision == 1, host.measureRequests == 1,
                  host.acceptedMeasurementChanges == 1, let measurement = host.measurement,
                  let correctedRow = host.rowFrame, let scale = after.displayScale, scale > 0,
                  correctedRow.height == (measurement.height * scale).rounded(.up) / scale,
                  let admission = host.admission, !admission.required,
                  after.viewport.height > before.viewport.height,
                  abs(after.viewport.width - before.viewport.width) < 0.5,
                  !admission.row.intersects(originalPreparation),
                  !correctedRow.intersects(originalPreparationInFinal),
                  correctedRow.intersects(finalPreparation),
                  admission.row.intersects(admission.viewport.insetBy(dx: 0, dy: -admission.viewport.height)) else { return nil }
        }
        for counter in ["native.rowHostCreated", "native.rowHostUpdated", "native.rowMeasureRequested"] {
            guard countsAfter[counter, default: 0] - countsBefore[counter, default: 0] == added.count else { return nil }
        }
        return added
    }

    init(plan: BenchPlan, workspace: ChatWorkspaceModel, output: URL) {
        self.plan = plan
        self.workspace = workspace
        self.output = output
    }

    func run() async throws -> [String: Any] {
        if plan.persistence == true { return try await runPersistence() }
        if plan.switches == true { return try await runSwitches() }
        try validateGeometryContracts()
        let address = ConversationAddress(hostID: plan.host, threadID: plan.thread)
        let opened = ContinuousClock.now
        try await open(address)
        let loadMs = opened.duration(to: .now) / .milliseconds(1)
        logger.notice("perf bench transcript loaded ms=\(loadMs, privacy: .public)")
        let (window, scrollView) = try await transcript()
        place(window)
        try await activate(window)
        try await Task.sleep(for: .seconds(plan.settleSeconds))
        try validateDisplay(window.screen)
        let point = pointer(in: scrollView)
        CGWarpMouseCursorPosition(point)
        if !plan.warmup.isEmpty {
            _ = try await perform(plan.warmup, at: point, window: window, scrollView: scrollView, meter: nil, stream: nil)
            try await Task.sleep(for: .seconds(plan.settleSeconds))
        }
        let stream = try await prepareStream(address)
        var fixtureRowID: String?
        if plan.fixture == .horizontalOverflow {
            guard let screen = workspace.selectedScreen, screen.executionTarget == address.target,
                  let session = screen.selectedConversation else { throw BenchFailure("overflow fixture lost its selected conversation") }
            let rowID = try await BenchStream.populateHorizontalOverflow(session: session, threadID: address.threadID)
            guard workspace.selectedScreen === screen, screen.selectedConversation === session else {
                throw BenchFailure("overflow conversation changed during preparation")
            }
            overflowRowID = rowID
            fixtureRowID = rowID
            screen.revealTranscriptRow(rowID)
        }
        if plan.fixture == .coldTable {
            guard plan.stream == nil, plan.checkInteraction == nil,
                  let screen = workspace.selectedScreen, screen.executionTarget == address.target,
                  let session = screen.selectedConversation,
                  let container = scrollView as? AppKitTranscriptContainer else {
                throw BenchFailure("cold-table requires an idle probe with no concurrent stream or interaction check")
            }
            fixtureRowID = try await BenchStream.populateColdTable(session: session, threadID: address.threadID)
            try await Task.sleep(for: .milliseconds(500))
            guard let fixtureRowID, container.hostedRowForBench(id: fixtureRowID) == nil,
                  container.isFollowingLatest(), screen.messages.contains(where: { ChatStreamItem.message($0).id == fixtureRowID }) else {
                throw BenchFailure("cold-table did not retain its source message with its host evicted")
            }
            PerfHarness.emit(["bench": "fixture", "kind": "cold-table", "rowID": fixtureRowID,
                              "messages": screen.messages.count, "hostEvicted": true])
        }
        let validity = BenchmarkWindowObservation(window: window)
        try validity.validate()
        PerfHarness.emit(["bench": "visibility", "visible": true])
        var recorder: WindowRecorder? = switch plan.capture {
        case .none: nil
        case .frames: try await WindowRecorder.start(window: window, video: nil)
        case .video: try await WindowRecorder.start(window: window, video: output.appending(path: "video.mov"))
        }
        defer {
            if let recorder {
                do { _ = try await recorder.finish() }
                catch { logger.error("benchmark capture cleanup failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        try validity.validate()
        let meter = FrameMeter(window: window, scrollView: scrollView)
        defer { meter.stop() }
        let startCPU = ProcessMetrics.processCPUSeconds()
        let startMainCPU = ProcessMetrics.mainThreadCPUSeconds()
        let startFootprint = ProcessMetrics.footprint()
        if let frame = window.contentView?.superview {
            let middle = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil)
            var view = frame.hitTest(frame.convert(middle, from: nil))
            var chain: [String] = []
            while let current = view, chain.count < 16 {
                chain.append(String(describing: type(of: current)))
                view = current.superview
            }
            PerfHarness.emit(["bench": "hit", "chain": chain])
        }
        let messagesStart = workspace.selectedScreen?.messages.count ?? 0
        PerfHarness.emit(["bench": "measuring", "pid": Int(getpid())])
        let events = try await perform(plan.gestures, at: point, window: window, scrollView: scrollView, meter: meter, stream: stream)
        PerfHarness.emit(["bench": "tail", "seconds": plan.tailSeconds])
        try await Task.sleep(for: .seconds(plan.tailSeconds))
        try validateDisplay(window.screen)
        let endCPU = ProcessMetrics.processCPUSeconds()
        let endMainCPU = ProcessMetrics.mainThreadCPUSeconds()
        let endFootprint = ProcessMetrics.footprint()
        let frames = meter.finish()
        let completedRecorder = recorder
        recorder = nil
        let recording = try await completedRecorder?.finish()
        try validity.validate()
        let screen = window.screen
        return try frames.counterWindow.report([
            "loadMs": loadMs,
            "messages": workspace.selectedScreen?.messages.count ?? 0,
            "messagesStart": messagesStart,
            "measurementHost": ProcessInfo.processInfo.hostName,
            "display": [
                "maximumFramesPerSecond": screen?.maximumFramesPerSecond ?? 0,
                "scale": screen?.backingScaleFactor ?? 0,
                "width": screen?.frame.width ?? 0,
                "height": screen?.frame.height ?? 0,
            ],
            "window": ["width": window.frame.width, "height": window.frame.height],
            "windowOcclusionVisible": window.occlusionState.contains(.visible),
            "appearance": window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown",
            "scrollerStyle": NSScroller.preferredScrollerStyle.rawValue,
            "transcript": [
                "width": scrollView.contentView.bounds.width,
                "height": scrollView.contentView.bounds.height,
                "documentHeightEnd": scrollView.documentView?.frame.height ?? 0,
            ],
            "pointer": ["x": point.x, "y": point.y],
            "frames": frames.frames,
            "bounds": frames.bounds,
            "marks": frames.marks,
            "spans": frames.spans,
            "spanRecording": frames.spanRecording,
            "events": events,
            "stream": plan.stream?.report ?? NSNull(),
            "fixture": plan.fixture?.rawValue ?? NSNull(),
            "fixtureRowID": fixtureRowID ?? NSNull(),
            "measureStart": frames.started,
            "measureEnd": frames.ended,
            "analysisScope": plan.gestures.isEmpty ? "window" : "motion",
            "processCPUms": ProcessMetrics.cpuMilliseconds(from: startCPU, to: endCPU).map { $0 as Any } ?? NSNull(),
            "mainThreadCPUms": ProcessMetrics.cpuMilliseconds(from: startMainCPU, to: endMainCPU).map { $0 as Any } ?? NSNull(),
            "footprintStartMB": ProcessMetrics.megabytes(startFootprint).map { $0 as Any } ?? NSNull(),
            "footprintEndMB": ProcessMetrics.megabytes(endFootprint).map { $0 as Any } ?? NSNull(),
            "recording": recording ?? NSNull(),
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "gauges": PerfBuild.gauges,
        ])
    }

    private func prepareStream(_ address: ConversationAddress) async throws -> BenchStream? {
        guard let plan = plan.stream else { return nil }
        guard let screen = workspace.selectedScreen, screen.executionTarget == address.target,
              screen.activeSessionID == address.threadID, let session = screen.selectedConversation else {
            throw BenchFailure("streaming conversation is no longer selected")
        }
        let stream = try await BenchStream.prepare(plan: plan, session: session, threadID: address.threadID)
        guard workspace.selectedScreen === screen, screen.selectedConversation === session,
              screen.activeSessionID == address.threadID else { throw BenchFailure("streaming conversation changed during preparation") }
        return stream
    }

    private func validateDisplay(_ screen: NSScreen?) throws {
        guard let screen, screen.frame.width == plan.expectedDisplay.width,
              screen.frame.height == plan.expectedDisplay.height,
              screen.backingScaleFactor == plan.expectedDisplay.scale,
              screen.maximumFramesPerSecond == plan.expectedDisplay.maximumFramesPerSecond else {
            throw BenchFailure("display resolution, scale or refresh differs from the requested measurement mode")
        }
    }

    private func runPersistence() async throws -> [String: Any] {
        try validateGeometryContracts()
        let deadline = ContinuousClock.now + .seconds(10)
        while workspace.screen(for: plan.host) == nil {
            guard ContinuousClock.now < deadline else { throw BenchFailure("missing persistence target") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let target = workspace.screen(for: plan.host)?.target,
              workspace.settings.hosts.count == 1 else { throw BenchFailure("persistence requires isolated storage") }
        let fixture = try await SwitchFixture.make(name: "persistence", messages: 1_000,
            directory: output.appending(path: "fixtures/persistence"))
        target.switchFixtures[fixture.header.id] = fixture
        defer { target.switchFixtures.removeValue(forKey: fixture.header.id) }
        try await fixture.session.restore()
        await target.renderedMessages.prepare(await fixture.session.snapshot().messages)
        try await open(ConversationAddress(hostID: plan.host, threadID: fixture.header.id))
        let (window, scroll) = try await transcript()
        place(window)
        try await activate(window)
        try validateDisplay(window.screen)
        try await Task.sleep(for: .seconds(plan.settleSeconds))
        guard let container = scroll as? AppKitTranscriptContainer,
              let screen = workspace.selectedScreen else { throw BenchFailure("missing persistence transcript") }
        let meter = FrameMeter(window: window, scrollView: scroll)
        meter.start()
        defer { meter.stop() }
        _ = try await meter.firstVsync()
        PerfHarness.emit(["bench": "measuring", "pid": Int(getpid())])
        let startedCPU = ProcessMetrics.processCPUSeconds()
        let startedMain = ProcessMetrics.mainThreadCPUSeconds()
        let startedFootprint = ProcessMetrics.footprint()
        var results: [[String: Any]] = []
        for index in 0..<3 {
            let message = ChatMessage(role: .user, text: "Small persistence fixture send \(index)")
            let bytes = ProcessMetrics.logicalWrites()
            let logical = PersistenceMetrics.shared.snapshot()[.checkpoints]?.bytes ?? 0
            let cpu = ProcessMetrics.mainThreadCPUSeconds()
            let requested = CACurrentMediaTime()
            let snapshot = try await fixture.session.submit(message)
            await screen.publish(snapshot)
            let persistence = Task {
                try await fixture.session.persistSubmission(message.id)
                return CACurrentMediaTime()
            }
            let readyDeadline = ContinuousClock.now + .seconds(5)
            while container.hostedRowForBench(id: "message-\(message.id.uuidString)") == nil || !container.isLayoutReadyForBench {
                guard ContinuousClock.now < readyDeadline else { throw BenchFailure("submitted row did not mount") }
                try await Task.sleep(for: .milliseconds(1))
            }
            let ready = CACurrentMediaTime()
            let durable = try await persistence.value
            var result: [String: Any] = ["kind": "send", "durableMs": (durable - requested) * 1_000,
                "rowMountedMs": (ready - requested) * 1_000,
                "mainThreadCPUms": ProcessMetrics.cpuMilliseconds(from: cpu, to: ProcessMetrics.mainThreadCPUSeconds()).map { $0 as Any } ?? NSNull(),
                "encodedBytes": (PersistenceMetrics.shared.snapshot()[.checkpoints]?.bytes ?? 0) - logical]
            if let bytes, let end = ProcessMetrics.logicalWrites() { result["processLogicalBytes"] = end - bytes }
            else { result["processLogicalBytes"] = NSNull() }
            result.merge(meter.work(from: requested, until: ready)) { _, measured in measured }
            results.append(result)
            await fixture.session.accepted(message.id, turnID: "persistence-send-\(index)")
            try await Task.sleep(for: .milliseconds(100))
        }
        let bytes = ProcessMetrics.logicalWrites()
        let logical = PersistenceMetrics.shared.snapshot()[.checkpoints]?.bytes ?? 0
        let cpu = ProcessMetrics.mainThreadCPUSeconds()
        let started = CACurrentMediaTime()
        let thread = fixture.header.id
        let turn = "persistence-stream"
        let chunk = String(repeating: "A streaming persistence fixture. ", count: 20)
        for index in 0..<20 {
            let params = JSONValue.object(["threadId": .string(thread), "turnId": .string(turn),
                "itemId": .string("persistence-answer"), "delta": .string(chunk)])
            let method = "item/agentMessage/delta"
            let note = CodexGatewayNotification(method: method, params: params,
                server: ServerNotification.decode(method: method, params: params))
            guard case .turnEvent(let event) = GatewayNotificationRouting.route(note) else { throw BenchFailure("invalid stream fixture") }
            await fixture.session.ingest(event, replay: false)
            if index == 9 || index == 19 { try await fixture.session.flush() }
        }
        var stream: [String: Any] = ["kind": "stream", "generatedUTF8Bytes": chunk.utf8.count * 20,
            "durationMs": (CACurrentMediaTime() - started) * 1_000,
            "mainThreadCPUms": ProcessMetrics.cpuMilliseconds(from: cpu, to: ProcessMetrics.mainThreadCPUSeconds()).map { $0 as Any } ?? NSNull(),
            "encodedBytes": (PersistenceMetrics.shared.snapshot()[.checkpoints]?.bytes ?? 0) - logical]
        if let bytes, let end = ProcessMetrics.logicalWrites() { stream["processLogicalBytes"] = end - bytes }
        else { stream["processLogicalBytes"] = NSNull() }
        results.append(stream)
        try await Task.sleep(for: .milliseconds(200))
        let frames = meter.finish()
        return try frames.counterWindow.report(["persistence": results, "frames": frames.frames, "bounds": frames.bounds, "events": [],
            "loadMs": NSNull(), "measurementHost": ProcessInfo.processInfo.hostName,
            "transcript": ["width": scroll.contentView.bounds.width, "height": scroll.contentView.bounds.height],
            "marks": frames.marks, "spans": frames.spans, "spanRecording": frames.spanRecording,
            "measureStart": frames.started, "measureEnd": frames.ended, "analysisScope": "window",
            "processCPUms": ProcessMetrics.cpuMilliseconds(from: startedCPU, to: ProcessMetrics.processCPUSeconds()).map { $0 as Any } ?? NSNull(),
            "mainThreadCPUms": ProcessMetrics.cpuMilliseconds(from: startedMain, to: ProcessMetrics.mainThreadCPUSeconds()).map { $0 as Any } ?? NSNull(),
            "messages": screen.messages.count,
            "footprintStartMB": ProcessMetrics.megabytes(startedFootprint).map { $0 as Any } ?? NSNull(),
            "footprintEndMB": ProcessMetrics.megabytes(ProcessMetrics.footprint()).map { $0 as Any } ?? NSNull(),
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "display": ["maximumFramesPerSecond": window.screen?.maximumFramesPerSecond ?? 0,
                "width": window.screen?.frame.width ?? 0, "height": window.screen?.frame.height ?? 0,
                "scale": window.screen?.backingScaleFactor ?? 0],
            "activeWindow": NSApp.isActive && window.isKeyWindow,
            "windowOcclusionVisible": window.occlusionState.contains(.visible),
            "window": ["width": window.frame.width, "height": window.frame.height],
            "gauges": PerfBuild.gauges])
    }

    private func runSwitches() async throws -> [String: Any] {
        try validateGeometryContracts()
        let deadline = ContinuousClock.now + .seconds(10)
        while workspace.screen(for: plan.host) == nil {
            guard ContinuousClock.now < deadline else { throw BenchFailure("missing fixture target") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let target = workspace.screen(for: plan.host)?.target,
              workspace.settings.hosts.count == 1, workspace.settings.hosts.first?.id == plan.host,
              workspace.models.allSatisfy({ $0.hostID == plan.host }) else {
            throw BenchFailure("switch fixtures require one isolated MacBook host")
        }
        for (name, count) in [("anchor", 1_000), ("short-cold", 6), ("long-cold", 1_000), ("short-warm", 6), ("long-warm", 1_000)] {
            let fixture = try await SwitchFixture.make(name: name, messages: count,
                directory: output.appending(path: "fixtures/\(name)"))
            target.switchFixtures[fixture.header.id] = fixture
            if name.hasSuffix("warm") || name == "anchor" {
                try await fixture.session.restore()
                let snapshot = await fixture.session.snapshot()
                await target.renderedMessages.prepare(snapshot.messages)
                target.recentConversations.record(snapshot, session: fixture.session)
            }
        }
        defer { target.switchFixtures.removeAll() }
        let anchor = ConversationAddress(hostID: plan.host, threadID: "claude_rc-switch-anchor")
        try await open(anchor)
        let (window, initialScroll) = try await transcript()
        place(window)
        try await Task.sleep(for: .seconds(plan.settleSeconds))
        try await activate(window)
        guard let initial = initialScroll as? AppKitTranscriptContainer,
              initial.presentedAddressForBench == anchor, initial.isLayoutReadyForBench else {
            throw BenchFailure("fixture anchor identity or layout is not ready")
        }
        let validity = BenchmarkWindowObservation(window: window)
        try validity.validate()
        var recorder: WindowRecorder? = switch plan.capture {
        case .none: nil
        case .frames: try await WindowRecorder.start(window: window, video: nil)
        case .video: try await WindowRecorder.start(window: window, video: output.appending(path: "video.mov"))
        }
        defer {
            if let recorder {
                do { _ = try await recorder.finish() }
                catch { logger.error("benchmark capture cleanup failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        try validity.validate()
        try validateDisplay(window.screen)
        let meter = FrameMeter(window: window, scrollView: initialScroll)
        defer { meter.stop() }
        let startProcessCPU = ProcessMetrics.processCPUSeconds()
        let startMainCPU = ProcessMetrics.mainThreadCPUSeconds()
        let startFootprint = ProcessMetrics.footprint()
        let messagesStart = workspace.selectedScreen?.messages.count
        meter.start()
        _ = try await meter.firstVsync()
        PerfHarness.emit(["bench": "measuring", "pid": Int(getpid())])
        let names = ["short-cold", "long-cold", "short-warm", "long-warm", "short-warm", "long-warm", "short-cold", "long-cold"]
        var results: [[String: Any]] = []
        var savedStates: [String: SwitchReturnState] = [:]
        for name in names {
            let threadID = "claude_rc-switch-\(name)"
            let address = ConversationAddress(hostID: plan.host, threadID: threadID)
            PerfHarness.shared.resetFirstReady(threadID: threadID)
            let countsBefore = PerfBuild.counters
            let startCPU = ProcessMetrics.mainThreadCPUSeconds()
            let requested = CACurrentMediaTime()
            guard workspace.switchConversation(to: address) == .changed else { throw BenchFailure("fixture switch refused") }
            let deadline = ContinuousClock.now + .seconds(15)
            while PerfHarness.shared.firstReadyEvents[threadID] == nil {
                guard ContinuousClock.now < deadline else { throw BenchFailure("fixture viewport never became ready") }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard let ready = PerfHarness.shared.firstReadyEvents[threadID] else { throw BenchFailure("missing viewport-ready event") }
            let (_, current) = try await transcript()
            guard let container = current as? AppKitTranscriptContainer, container.presentedAddressForBench == address,
                  let selected = workspace.selectedScreen, workspace.isShowingConversation(at: address, on: selected),
                  selected.messages.last?.text.hasPrefix("## \(name.uppercased())") == true else {
                throw BenchFailure("presented fixture identity differs from the selection")
            }
            meter.observeScrollView(current)
            let tolerance = 1 / window.backingScaleFactor
            let saved = savedStates[name]?.position
            let preserved = saved.map { $0.isPreserved(in: ready.hosts, tolerance: tolerance) }
            let readingPreserved: Bool? = if case .reading? = saved { preserved } else { nil }
            let latestPreserved: Bool? = if case .latest? = saved { preserved } else { nil }
            let warmReturn = name.hasSuffix("warm") && savedStates[name] != nil
            let updatedHosts = ready.counters["native.rowHostUpdated", default: 0] - countsBefore["native.rowHostUpdated", default: 0]
            let rowMeasures = ready.counters["native.rowMeasureRequested", default: 0] - countsBefore["native.rowMeasureRequested", default: 0]
            let reusedSurfaces = ready.counters["native.surfaceReused", default: 0] - countsBefore["native.surfaceReused", default: 0]
            let addedHosts = savedStates[name].flatMap {
                verifiedNewHosts(from: $0.hosts, to: ready.hosts, countsBefore: countsBefore, countsAfter: ready.counters)
            }
            if warmReturn {
                guard preserved == true, reusedSurfaces == 1, addedHosts != nil else {
                    PerfHarness.emit(["bench": "reading", "threadID": threadID, "phase": "returnFailed",
                        "expectedMode": saved?.mode ?? "unknown", "state": container.readingStateForBench(),
                        "createdRowHostsToReady": ready.counters["native.rowHostCreated", default: 0] - countsBefore["native.rowHostCreated", default: 0]])
                    throw BenchFailure("unchanged warm return \(name) failed its \(saved?.mode ?? "unknown") position or row reuse: reused=\(reusedSurfaces), updated=\(updatedHosts), measures=\(rowMeasures), positionPreserved=\(preserved == true)")
                }
            }
            results.append(["name": name, "requestedAt": requested, "rowReadyAt": ready.time,
                "rowReadyMs": (ready.time - requested) * 1_000,
                "mainThreadCPUToReadyMs": ProcessMetrics.cpuMilliseconds(from: startCPU, to: ready.mainCPU).map { $0 as Any } ?? NSNull(),
                "scrollOrigin": current.contentView.bounds.origin.y,
                "readingPositionPreserved": readingPreserved.map { $0 as Any } ?? NSNull(),
                "followingLatestPreserved": latestPreserved.map { $0 as Any } ?? NSNull(),
                "returnPositionPreserved": preserved.map { $0 as Any } ?? NSNull(),
                "returnMode": saved.map { $0.mode as Any } ?? NSNull(),
                "identityVerified": true,
                "createdRowHostsToReady": ready.counters["native.rowHostCreated", default: 0] - countsBefore["native.rowHostCreated", default: 0],
                "updatedRowHostsToReady": updatedHosts,
                "rowMeasuresToReady": rowMeasures,
                "reusedNativeSurfacesToReady": reusedSurfaces,
                "unchangedWarmReturnVerified": warmReturn,
                "retainedRowHostsVerifiedToReady": savedStates[name].map { $0.hosts.rows.count as Any } ?? NSNull(),
                "updatedRetainedRowHostsToReady": warmReturn ? 0 as Any : NSNull(),
                "retainedRowMeasuresToReady": warmReturn ? 0 as Any : NSNull(),
                "retainedMeasurementChangesToReady": warmReturn ? 0 as Any : NSNull(),
                "newlyAdmittedRowIDsToReady": addedHosts.map { $0 as Any } ?? NSNull(),
                "retainedNativeSurfaces": workspace.retainedTranscripts.count,
                "hostPreparationsToReady": ready.counters["host.prepareStarted", default: 0] - countsBefore["host.prepareStarted", default: 0],
                "footprintMB": ProcessMetrics.megabytes(ProcessMetrics.footprint()).map { $0 as Any } ?? NSNull(),
                "documentHeight": current.documentView?.frame.height ?? 0,
                "messages": selected.messages.count])
            if let result = results.last { PerfHarness.emit(["bench": "switch", "result": result]) }
            try await Task.sleep(for: .milliseconds(350))
            if warmReturn {
                let settled = container.hostWorkForBench()
                let settledHosts = savedStates[name].flatMap {
                    verifiedNewHosts(from: $0.hosts, to: settled,
                        countsBefore: countsBefore, countsAfter: PerfBuild.counters)
                }
                guard saved?.isPreserved(in: settled, tolerance: tolerance) == true, settledHosts != nil else {
                    throw BenchFailure("unchanged warm return \(name) lost its position or updated or measured retained rows after becoming ready")
                }
                PerfHarness.emit(["bench": "reading", "threadID": threadID, "phase": "returnSettled",
                    "retainedRowHostsVerified": savedStates[name].map { $0.hosts.rows.count as Any } ?? NSNull(),
                    "newlyAdmittedRowIDs": settledHosts.map { $0 as Any } ?? NSNull(),
                    "updatedRetainedRowHosts": 0, "retainedRowMeasures": 0,
                    "retainedMeasurementChanges": 0, "positionPreserved": true])
            } else if name.hasSuffix("warm") {
                if name == "long-warm" {
                    container.navigate(.pageUp)
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard container.isLayoutReadyForBench else { throw BenchFailure("warm fixture \(name) has unsettled geometry") }
                if name == "long-warm" {
                    guard !container.isFollowingLatest(), let position = container.readingPositionForBench() else {
                        throw BenchFailure("warm fixture \(name) has no drawn reading row to retain")
                    }
                    savedStates[name] = SwitchReturnState(position: .reading(rowID: position.rowID, offset: position.offset),
                        hosts: container.hostWorkForBench())
                } else {
                    guard container.isFollowingLatest(), abs(container.latestDistanceForBench) <= tolerance else {
                        throw BenchFailure("warm fixture \(name) does not follow the displayed document end")
                    }
                    savedStates[name] = SwitchReturnState(position: .latest, hosts: container.hostWorkForBench())
                }
                PerfHarness.emit(["bench": "reading", "threadID": threadID, "phase": "savedExpected",
                    "state": container.readingStateForBench()])
            }
        }
        let processCPU = ProcessMetrics.cpuMilliseconds(from: startProcessCPU, to: ProcessMetrics.processCPUSeconds())
        let mainCPU = ProcessMetrics.cpuMilliseconds(from: startMainCPU, to: ProcessMetrics.mainThreadCPUSeconds())
        let endFootprint = ProcessMetrics.footprint()
        let frames = meter.finish()
        var recording: [String: Any]?
        let completedRecorder = recorder
        recorder = nil
        if let completedRecorder {
            do { recording = try await completedRecorder.finish() }
            catch { recording = ["error": String(describing: error)] }
        }
        try validity.validate()
        for index in results.indices {
            if let start = results[index]["requestedAt"] as? Double, let end = results[index]["rowReadyAt"] as? Double {
                results[index].merge(meter.work(from: start, until: end)) { _, measured in measured }
            }
        }
        let detachedStreaming = try await verifyDetachedStreaming(target: target)
        var validation: [String: Any] = [:]
        validation["detachedStreaming"] = detachedStreaming
        validation["restoredReturnContracts"] = try await verifyRestoredReturns(target: target)
        do {
            try validateDisplay(window.screen)
            PerfHarness.shared.resetFirstReady(threadID: "claude_rc-switch-short-cold")
            for name in names.reversed() {
                _ = workspace.switchConversation(to: ConversationAddress(hostID: plan.host, threadID: "claude_rc-switch-\(name)"))
            }
            let rapidDeadline = ContinuousClock.now + .seconds(5)
            while !workspace.isShowingConversation(at: ConversationAddress(hostID: plan.host, threadID: "claude_rc-switch-short-cold"), on: workspace.selectedScreen)
                    || PerfHarness.shared.firstReadyEvents["claude_rc-switch-short-cold"] == nil {
                guard ContinuousClock.now < rapidDeadline else { throw BenchFailure("rapid switches did not settle on the last identity") }
                try await Task.sleep(for: .milliseconds(4))
            }
            let (_, current) = try await transcript()
            guard (current as? AppKitTranscriptContainer)?.presentedAddressForBench == ConversationAddress(hostID: plan.host, threadID: "claude_rc-switch-short-cold") else {
                throw BenchFailure("rapid switch presented a different identity")
            }
            validation["rapidSwitchIdentity"] = true
        } catch { validation["error"] = String(describing: error) }
        try validity.validate()
        return try frames.counterWindow.report(["switches": results, "validation": validation, "frames": frames.frames, "bounds": frames.bounds,
            "events": [], "loadMs": NSNull(), "measurementHost": ProcessInfo.processInfo.hostName,
            "transcript": ["width": initialScroll.contentView.bounds.width, "height": initialScroll.contentView.bounds.height],
            "marks": frames.marks, "spans": frames.spans, "spanRecording": frames.spanRecording,
            "recording": recording ?? NSNull(), "measureStart": frames.started, "measureEnd": frames.ended,
            "analysisScope": "window", "processCPUms": processCPU.map { $0 as Any } ?? NSNull(),
            "mainThreadCPUms": mainCPU.map { $0 as Any } ?? NSNull(),
            "messages": workspace.selectedScreen?.messages.count ?? 0, "messagesStart": messagesStart ?? NSNull(),
            "footprintStartMB": ProcessMetrics.megabytes(startFootprint).map { $0 as Any } ?? NSNull(),
            "footprintEndMB": ProcessMetrics.megabytes(endFootprint).map { $0 as Any } ?? NSNull(),
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "display": ["maximumFramesPerSecond": window.screen?.maximumFramesPerSecond ?? 0,
                        "width": window.screen?.frame.width ?? 0, "height": window.screen?.frame.height ?? 0,
                        "scale": window.screen?.backingScaleFactor ?? 0],
            "activeWindow": NSApp.isActive && window.isKeyWindow,
            "windowOcclusionVisible": window.occlusionState.contains(.visible),
            "window": ["width": window.frame.width, "height": window.frame.height],
            "gauges": PerfBuild.gauges])
    }

    private func returnFixture(_ name: String) async throws -> AppKitTranscriptContainer {
        let threadID = "claude_rc-switch-\(name)"
        let address = ConversationAddress(hostID: plan.host, threadID: threadID)
        PerfHarness.shared.resetFirstReady(threadID: threadID)
        guard workspace.switchConversation(to: address) == .changed else { throw BenchFailure("return validation switch refused") }
        let deadline = ContinuousClock.now + .seconds(10)
        while PerfHarness.shared.firstReadyEvents[threadID] == nil {
            guard ContinuousClock.now < deadline else { throw BenchFailure("return validation did not mount content") }
            try await Task.sleep(for: .milliseconds(4))
        }
        let (_, scroll) = try await transcript()
        guard let container = scroll as? AppKitTranscriptContainer, container.presentedAddressForBench == address else {
            throw BenchFailure("return validation mounted a different conversation")
        }
        return container
    }

    private func publishReturnContinuation(_ fixture: SwitchFixture, id: String) async throws {
        let threadID = fixture.header.id
        let item: [String: JSONValue] = ["type": .string("agentMessage"), "id": .string(id), "text": .string("")]
        await fixture.session.ingest(try await SwitchFixture.event("item/started", params: [
            "threadId": .string(threadID), "turnId": .string(id), "item": .object(item),
            "startedAtOrdinal": .number(0), "startedAtMs": .number(1)]), replay: false)
        let text = String(repeating: "Content added after the restored reader.\n\n", count: 16)
        await fixture.session.ingest(try await SwitchFixture.event("item/agentMessage/delta", params: [
            "threadId": .string(threadID), "turnId": .string(id), "itemId": .string(id), "delta": .string(text)]), replay: false)
        await fixture.session.ingest(try await SwitchFixture.event("item/completed", params: [
            "threadId": .string(threadID), "turnId": .string(id),
            "item": .object(["type": .string("agentMessage"), "id": .string(id), "text": .string(text)]),
            "startedAtOrdinal": .number(0), "completedAtMs": .number(2)]), replay: false)
        await fixture.session.ingest(try await SwitchFixture.event("turn/completed", params: [
            "threadId": .string(threadID), "turn": .object(["id": .string(id), "status": .string("completed"),
                "items": .array([])])]), replay: false)
        try await Task.sleep(for: .milliseconds(500))
        guard workspace.selectedScreen?.messages.contains(where: { $0.text == text }) == true else {
            throw BenchFailure("return validation did not publish the continuation")
        }
    }

    private func emitReconstructedReading(_ phase: String, container: AppKitTranscriptContainer,
                                          owner: TranscriptReadingPosition) {
        PerfHarness.emit(["bench": "reconstructed-reading", "phase": phase,
            "state": container.readingStateForBench(), "bookmark": PerfHarness.readingBookmark(owner),
            "fixtureOwnsReading": container.hasReadingOwnerForBench(owner)])
    }

    private func verifyRestoredReturns(target: ChatTargetModel) async throws -> [String: Any] {
        guard let fixture = target.switchFixtures["claude_rc-switch-long-warm"],
              let saved = fixture.session.readingPosition.anchor, !fixture.session.readingPosition.isFollowingLatest else {
            throw BenchFailure("return validation lacks a retained reading bookmark")
        }
        let tolerance = 1 / (NSApp.keyWindow?.backingScaleFactor ?? 1)
        workspace.retainedTranscripts.removeAll()
        target.recentConversations.removeAll(keeping: ["claude_rc-switch-long-cold"])
        let first = try await returnFixture("long-warm")
        guard let restored = first.readingPositionForBench(), restored.rowID == saved.rowID,
              abs(restored.offset - saved.rowOffset) <= tolerance, !first.isFollowingLatest() else {
            throw BenchFailure("late retained owner failed to restore before the first ready frame")
        }
        try await publishReturnContinuation(fixture, id: "late-owner-continuation")
        guard let afterPublication = first.readingPositionForBench(), afterPublication.rowID == restored.rowID,
              abs(afterPublication.offset - restored.offset) <= tolerance, !first.isFollowingLatest() else {
            throw BenchFailure("late retained owner resumed following after publication")
        }
        first.navigate(.pageUp)
        try await Task.sleep(for: .milliseconds(500))
        emitReconstructedReading("beforeZoom", container: first, owner: fixture.session.readingPosition)
        guard let page = first.readingPositionForBench(), !first.isFollowingLatest(),
              let menu = NSApp.mainMenu, performMenuAction("Zoom In", in: menu) else {
            throw BenchFailure("return validation cannot change interface zoom while reading")
        }
        defer { if let menu = NSApp.mainMenu { _ = performMenuAction("Actual Size", in: menu) } }
        try await Task.sleep(for: .milliseconds(500))
        emitReconstructedReading("zoomed", container: first, owner: fixture.session.readingPosition)
        guard let zoomed = first.readingPositionForBench(), zoomed.rowID == page.rowID,
              abs(zoomed.scale - 1.1) < 0.001, abs(zoomed.height - first.contentView.bounds.height) > 0.5,
              abs(zoomed.fraction - page.fraction) * zoomed.height <= tolerance,
              !zoomed.reflowPending, !first.isFollowingLatest() else {
            throw BenchFailure("return validation did not preserve the mounted reader through Zoom In")
        }
        guard let menu = NSApp.mainMenu, performMenuAction("Actual Size", in: menu) else {
            throw BenchFailure("return validation cannot prepare the Actual Size bookmark")
        }
        try await Task.sleep(for: .milliseconds(500))
        let fraction: CGFloat = 0.95
        let actualSize = first.readingPositionForBench()
        PerfHarness.emit(["bench": "reconstructed-reading", "phase": "shrinkSetup",
            "state": first.readingStateForBench(), "zoomedRowID": zoomed.rowID,
            "zoomedHeight": zoomed.height, "zoomedScale": zoomed.scale, "zoomedColumnWidth": zoomed.width,
            "savingHeight": actualSize.map { $0.height as Any } ?? NSNull(),
            "plannedOffset": actualSize.map { (fraction * $0.height) as Any } ?? NSNull(),
            "savedOffsetExceedsTargetHeight": actualSize.map { (fraction * $0.height > zoomed.height) as Any } ?? NSNull()])
        guard let saving = actualSize, saving.rowID == zoomed.rowID, abs(saving.scale - 1) < 0.001,
              abs(saving.fraction - page.fraction) * saving.height <= tolerance,
              abs(saving.height - first.contentView.bounds.height) > 0.5,
              !saving.reflowPending, !first.isFollowingLatest(), fraction * saving.height > zoomed.height else {
            throw BenchFailure("reconstruction fixture did not prepare a shrinking row with an out-of-bounds saved offset")
        }
        let alignment = fraction * saving.height / (saving.height - first.contentView.bounds.height)
        var aligned = false
        first.alignRow(saving.rowID, anchor: UnitPoint(x: 0, y: alignment), animated: false) { aligned = true }
        try await Task.sleep(for: .milliseconds(500))
        guard aligned, let beforeReflow = first.readingPositionForBench(), beforeReflow.rowID == saving.rowID,
              abs(beforeReflow.fraction - fraction) * beforeReflow.height <= tolerance,
              beforeReflow.offset > zoomed.height else {
            throw BenchFailure("return validation did not reach its deep in-row bookmark")
        }
        first.captureReadingPosition()
        emitReconstructedReading("deepSaved", container: first, owner: fixture.session.readingPosition)
        _ = try await returnFixture("short-cold")
        emitReconstructedReading("departed", container: first, owner: fixture.session.readingPosition)
        guard let menu = NSApp.mainMenu, performMenuAction("Zoom In", in: menu) else {
            throw BenchFailure("return validation cannot prepare the shorter reconstruction layout")
        }
        try await Task.sleep(for: .milliseconds(500))
        workspace.retainedTranscripts.removeAll()
        emitReconstructedReading("beforeReturn", container: first, owner: fixture.session.readingPosition)
        let returned = try await returnFixture("long-warm")
        let observed = returned.readingPositionForBench()
        let predicates: [String: Any] = [
            "hasReadingPosition": observed != nil,
            "savedOffsetExceedsReturnedHeight": observed.map { (beforeReflow.offset > $0.height) as Any } ?? NSNull(),
            "sameRow": observed.map { ($0.rowID == beforeReflow.rowID) as Any } ?? NSNull(),
            "reflowFinished": observed.map { (!$0.reflowPending) as Any } ?? NSNull(),
            "fractionPreserved": observed.map { (abs($0.fraction - beforeReflow.fraction) * $0.height <= tolerance) as Any } ?? NSNull(),
            "staysReading": !returned.isFollowingLatest()]
        PerfHarness.emit(["bench": "reconstructed-reading", "phase": "returned",
            "firstReady": PerfHarness.shared.firstReadyEvents[fixture.header.id].map { $0.reading as Any } ?? NSNull(),
            "observed": returned.readingStateForBench(), "bookmark": PerfHarness.readingBookmark(fixture.session.readingPosition),
            "fixtureOwnsReading": returned.hasReadingOwnerForBench(fixture.session.readingPosition),
            "expectedRowID": beforeReflow.rowID, "expectedOffset": beforeReflow.offset,
            "expectedFraction": beforeReflow.fraction, "expectedHeight": beforeReflow.height,
            "requestedFraction": fraction, "alignment": alignment, "alignmentCompleted": aligned,
            "tolerance": tolerance,
            "relativeDisplacement": observed.map { (($0.fraction - beforeReflow.fraction) * $0.height) as Any } ?? NSNull(),
            "predicates": predicates])
        guard let afterReflow = observed, beforeReflow.offset > afterReflow.height,
              afterReflow.rowID == beforeReflow.rowID, !afterReflow.reflowPending,
              abs(afterReflow.fraction - beforeReflow.fraction) * afterReflow.height <= tolerance,
              !returned.isFollowingLatest() else {
            throw BenchFailure("reconstructed return landed outside the resized saved row")
        }
        guard let ready = PerfHarness.shared.firstReadyEvents[fixture.header.id],
              let readyPoint = ready.hosts.readingPoint, readyPoint.rowID == beforeReflow.rowID,
              let readyRow = ready.hosts.rows[readyPoint.rowID]?.rowFrame,
              beforeReflow.offset > readyRow.height,
              abs(readyPoint.offset - beforeReflow.fraction * readyRow.height) <= tolerance,
              !ready.hosts.followingLatest, let readyState = ready.reading["state"] as? [String: Any],
              readyState["reflowPending"] as? Bool == false else {
            throw BenchFailure("reconstructed return did not preserve the shrinking-row bookmark at first readiness")
        }
        try await publishReturnContinuation(fixture, id: "reflow-return-continuation")
        guard let settled = returned.readingPositionForBench(), settled.rowID == afterReflow.rowID,
              abs(settled.offset - afterReflow.offset) <= tolerance, !returned.isFollowingLatest() else {
            throw BenchFailure("reconstructed return lost its row on the next commit")
        }
        guard let unavailable = try await returned.unavailableReadingForBench(), unavailable.sourceRemoved,
              unavailable.renderUnavailable, unavailable.explicitRetry else {
            throw BenchFailure("unavailable native reading target did not terminate and preserve its bookmark")
        }
        let result: [String: Any] = ["lateOwnerRestoredBeforeContent": true, "lateOwnerStayedReadingAfterPublication": true,
            "mountedZoomPreservedReading": true, "shrinkingRowFixtureVerified": true,
            "reconstructedReflowRestoredBeforeContent": true,
            "reconstructedReflowRestoredRow": true, "reconstructedReflowStayedAfterPublication": true,
            "nativeMissingSourceTerminated": unavailable.sourceRemoved,
            "nativeUnavailableRenderTerminated": unavailable.renderUnavailable,
            "nativeUnavailableTargetAllowsExplicitRetry": unavailable.explicitRetry,
            "offsetBeforeReflow": beforeReflow.offset, "heightAfterReflow": afterReflow.height,
            "relativeDisplacement": (afterReflow.fraction - beforeReflow.fraction) * afterReflow.height]
        PerfHarness.emit(["bench": "check", "restoredReturnContracts": result])
        return result
    }

    private func verifyDetachedStreaming(target: ChatTargetModel) async throws -> [String: Any] {
        guard let fixture = target.switchFixtures["claude_rc-switch-long-cold"],
              workspace.selectedScreen?.activeSessionID == fixture.header.id else {
            throw BenchFailure("missing active switch streaming fixture")
        }
        let retained = workspace.retainedTranscripts.count
        let footprint = ProcessMetrics.megabytes(ProcessMetrics.footprint())
        let before = PerfBuild.counters
        let turnID = "detached-stream"
        let itemID = "detached-answer"
        let item: [String: JSONValue] = ["type": .string("agentMessage"), "id": .string(itemID), "text": .string("")]
        await fixture.session.ingest(try await SwitchFixture.event("item/started", params: [
            "threadId": .string(fixture.header.id), "turnId": .string(turnID), "item": .object(item),
            "startedAtOrdinal": .number(1), "startedAtMs": .number(1)]), replay: false)
        var text = ""
        var sawStreaming = false
        for index in 0..<8 {
            let delta = "Streaming while three prior conversations remain detached. Part \(index).\n\n"
            text += delta
            await fixture.session.ingest(try await SwitchFixture.event("item/agentMessage/delta", params: [
                "threadId": .string(fixture.header.id), "turnId": .string(turnID), "itemId": .string(itemID),
                "delta": .string(delta)]), replay: false)
            try await Task.sleep(for: .milliseconds(80))
            sawStreaming = sawStreaming || workspace.selectedScreen?.messages.contains(where: \.isStreaming) == true
        }
        await fixture.session.ingest(try await SwitchFixture.event("item/completed", params: [
            "threadId": .string(fixture.header.id), "turnId": .string(turnID),
            "item": .object(["type": .string("agentMessage"), "id": .string(itemID), "text": .string(text)]),
            "startedAtOrdinal": .number(1), "completedAtMs": .number(2)]), replay: false)
        try await Task.sleep(for: .milliseconds(150))
        let bodies = PerfBuild.counters["native.detachedBody", default: 0] - before["native.detachedBody", default: 0]
        let layouts = PerfBuild.counters["native.detachedLayout", default: 0] - before["native.detachedLayout", default: 0]
        let result: [String: Any] = ["retainedSurfaces": retained, "detachedBodyEvaluations": bodies,
            "detachedLayoutPasses": layouts, "activeStreamingVerified": sawStreaming,
            "footprintWithThreeRetainedMB": footprint.map { $0 as Any } ?? NSNull()]
        PerfHarness.emit(["bench": "detached-streaming", "result": result])
        guard retained == 3, bodies == 0, layouts == 0, sawStreaming else {
            throw BenchFailure("detached transcript streaming contract failed: \(result)")
        }
        return result
    }

    private func open(_ address: ConversationAddress) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while workspace.screen(for: address.hostID) == nil {
            guard ContinuousClock.now < deadline else { throw BenchFailure("host \(address.hostID) never became available") }
            try await Task.sleep(for: .milliseconds(50))
        }
        workspace.selectConversation(at: address)
        while !loaded(address) {
            guard ContinuousClock.now < deadline else { throw BenchFailure("the transcript did not load") }
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private func loaded(_ address: ConversationAddress) -> Bool {
        guard let screen = workspace.selectedScreen, screen.executionTarget == address.target,
              screen.openThreadID == address.threadID else { return false }
        return screen.loadingTranscriptID == nil && screen.alert?.message == nil && !screen.messages.isEmpty
    }

    func transcript() async throws -> (NSWindow, NSScrollView) {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            for window in NSApp.windows where window.isVisible {
                if let scrollView = TranscriptScrollHalt.transcriptScrollView(in: window) { return (window, scrollView) }
            }
            guard ContinuousClock.now < deadline else { throw BenchFailure("no visible transcript scroll view") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func place(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(plan.width, visible.width), height: min(plan.height, visible.height))
        window.setFrame(NSRect(x: visible.minX, y: visible.maxY - size.height, width: size.width, height: size.height), display: true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        PerfHarness.emit(["bench": "window-placed", "width": window.frame.width, "height": window.frame.height,
                          "keyWindow": window.isKeyWindow, "active": NSApp.isActive,
                          "occlusionVisible": window.occlusionState.contains(.visible)])
    }

    private func activate(_ window: NSWindow) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !NSApp.isActive || !window.isKeyWindow || !window.occlusionState.contains(.visible) {
            guard ContinuousClock.now < deadline else { throw BenchFailure("benchmark requires an active visible key window") }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func pointer(in scrollView: NSScrollView) -> CGPoint {
        let local = NSPoint(x: scrollView.bounds.minX + scrollView.bounds.width * plan.pointerX,
                            y: scrollView.bounds.minY + scrollView.bounds.height * plan.pointerY)
        let inWindow = scrollView.convert(local, to: nil)
        let onScreen = scrollView.window?.convertPoint(toScreen: inWindow) ?? inWindow
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y)
    }

    private func perform(_ gestures: [BenchGesture], at point: CGPoint, window: NSWindow, scrollView: NSScrollView,
                         meter: FrameMeter?, stream: BenchStream?) async throws -> [[Double]] {
        let vsync = FrameMeter(window: window, scrollView: scrollView)
        defer { vsync.stop() }
        let measuring = meter ?? vsync
        measuring.start()
        let started = ContinuousClock.now
        let (origin, period) = try await measuring.firstVsync()
        if meter == nil { vsync.stop() }
        let producer = GestureProducer(gestures: gestures, point: point, window: window, delivery: plan.delivery,
                                       origin: origin + period / 4, period: period)
        if let interaction = plan.checkInteraction {
            try await check(interaction, producer: producer, window: window, scrollView: scrollView, stream: stream)
            return []
        }
        async let streaming: Void? = stream?.run(started: started)
        let events = gestures.isEmpty ? [] : try await producer.run()
        _ = try await streaming
        return events
    }

    private func overflowingScroller(in view: NSView) -> NSScrollView? {
        overflowingScrollers(in: view).first
    }

    private func overflowingScrollers(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        for child in view.subviews {
            if let scroll = child as? NSScrollView,
               !scroll.visibleRect.isEmpty, let document = scroll.documentView,
               document.bounds.width > scroll.contentView.bounds.width + 1 {
                found.append(scroll)
                continue
            }
            found += overflowingScrollers(in: child)
        }
        return found
    }

    private func validateHostReuseContract() throws {
        let views = [NSView(), NSView(), NSView()]
        try withExtendedLifetime(views) {
            let viewport = CGRect(x: 0, y: 204_713.2, width: 1_138.5, height: 752)
            let admissionViewport = CGRect(x: 0, y: 204_713, width: 1_138.5, height: 774)
            let expandedViewport = CGRect(x: 0, y: 204_700, width: 1_138.5, height: 774)
            func snapshot(_ viewport: CGRect, rows: [String: TranscriptRowHost.WorkForBench]) -> AppKitTranscriptContainer.HostWorkForBench {
                .init(viewport: viewport, displayScale: 2, followingLatest: false, latestDistance: 655,
                    readingPoint: ("retained", 0), rows: rows)
            }
            let admission = TranscriptRowHost.AdmissionForBench(
                row: CGRect(x: 0, y: 203_746, width: 1_138.5, height: 194),
                viewport: admissionViewport, required: false)
            let retained = TranscriptRowHost.WorkForBench(view: views[0], rootRevision: 2,
                measureRequests: 3, measurement: CGSize(width: 832, height: 181), acceptedMeasurementChanges: 2,
                rowFrame: CGRect(x: 0, y: 204_714, width: 1_138.5, height: 181), admission: nil)
            let added = TranscriptRowHost.WorkForBench(view: views[1], rootRevision: 1,
                measureRequests: 1, measurement: CGSize(width: 832, height: 181), acceptedMeasurementChanges: 1,
                rowFrame: CGRect(x: 0, y: 203_746, width: 1_138.5, height: 181), admission: admission)
            let before = snapshot(viewport, rows: ["retained": retained])
            var correctedRetained = retained
            correctedRetained.rowFrame = CGRect(x: 0, y: 204_701, width: 1_138.5, height: 181)
            let expanded = snapshot(expandedViewport, rows: ["retained": correctedRetained, "overscan": added])
            let counters = ["native.rowHostCreated": 1, "native.rowHostUpdated": 1, "native.rowMeasureRequested": 1]
            guard verifiedNewHosts(from: before, to: before, countsBefore: [:], countsAfter: [:]) == [],
                  verifiedNewHosts(from: before, to: expanded, countsBefore: [:], countsAfter: counters) == ["overscan"] else {
                throw BenchFailure("native retained-host contract rejected unchanged hosts or viewport-growth admission")
            }
            var replaced = expanded
            replaced.rows["retained"]?.view = views[2]
            var updated = expanded
            updated.rows["retained"]?.rootRevision += 1
            var remeasured = expanded
            remeasured.rows["retained"]?.measureRequests += 1
            var repeatedNewMeasure = expanded
            repeatedNewMeasure.rows["overscan"]?.measureRequests += 1
            let alreadyEligible = snapshot(viewport.offsetBy(dx: 0, dy: -23), rows: before.rows)
            var repeatedNewCallback = expanded
            repeatedNewCallback.rows["overscan"]?.acceptedMeasurementChanges += 1
            var changedWithoutRequest = expanded
            changedWithoutRequest.rows["retained"]?.measurement = CGSize(width: 832, height: 182)
            changedWithoutRequest.rows["retained"]?.acceptedMeasurementChanges += 1
            var changedAndReturned = expanded
            changedAndReturned.rows["retained"]?.acceptedMeasurementChanges += 2
            var transientAdmission = expanded
            transientAdmission.rows["overscan"] = .init(view: views[1], rootRevision: 1,
                measureRequests: 1, measurement: CGSize(width: 832, height: 181), acceptedMeasurementChanges: 1,
                rowFrame: CGRect(x: 0, y: 203_540, width: 1_138.5, height: 181),
                admission: .init(row: CGRect(x: 0, y: 203_540, width: 1_138.5, height: 194),
                    viewport: CGRect(x: 0, y: 204_463, width: 1_138.5, height: 774), required: false))
            var extraWork = counters
            extraWork["native.rowHostUpdated"] = 2
            guard verifiedNewHosts(from: before, to: replaced, countsBefore: [:], countsAfter: counters) == nil,
                  verifiedNewHosts(from: before, to: updated, countsBefore: [:], countsAfter: counters) == nil,
                  verifiedNewHosts(from: before, to: remeasured, countsBefore: [:], countsAfter: counters) == nil,
                  verifiedNewHosts(from: before, to: repeatedNewMeasure, countsBefore: [:], countsAfter: counters) == nil,
                  verifiedNewHosts(from: before, to: repeatedNewCallback, countsBefore: [:], countsAfter: counters) == nil,
                  verifiedNewHosts(from: before, to: changedWithoutRequest, countsBefore: [:], countsAfter: counters) == nil,
                  verifiedNewHosts(from: before, to: changedAndReturned, countsBefore: [:], countsAfter: counters) == nil,
                  verifiedNewHosts(from: before, to: transientAdmission, countsBefore: [:], countsAfter: counters) == nil,
                  verifiedNewHosts(from: alreadyEligible, to: expanded, countsBefore: [:], countsAfter: counters) == nil,
                  verifiedNewHosts(from: before, to: expanded, countsBefore: [:], countsAfter: extraWork) == nil else {
                throw BenchFailure("native retained-host contract accepted replacement, remeasurement or unexplained admission work")
            }
        }
        PerfHarness.emit(["bench": "check", "retainedHostWorkContracts": true,
            "viewportGrowthAdmissionAccepted": true, "retainedReplacementRejected": true,
            "retainedUpdateRejected": true, "retainedRemeasureRejected": true,
            "repeatedNewMeasureRejected": true, "unexplainedAdmissionRejected": true,
            "changedMeasurementWithoutRequestRejected": true, "transientMeasurementChangeRejected": true,
            "repeatedNewMeasurementCallbackRejected": true,
            "transientShiftedAdmissionRejected": true])
    }

    private func validateGeometryContracts() throws {
        try validateHostReuseContract()
        let beforeRow = TranscriptRowIndex.Row(id: "reading", role: .reading, startsTurn: false,
                                             mountCost: 150, minY: 0, maxY: 1_000)
        let afterRow = TranscriptRowIndex.Row(id: "reading", role: .reading, startsTurn: false,
                                            mountCost: 150, minY: 0, maxY: 1_100)
        let bounds = CGRect(x: 0, y: 0, width: 836, height: 1_200)
        let viewport = CGRect(x: 0, y: 500, width: 836, height: 100)
        guard let before = TranscriptRowIndex(rows: [beforeRow], bounds: bounds),
              let after = TranscriptRowIndex(rows: [afterRow], bounds: bounds),
              let anchor = before.preservationAnchor(in: viewport, among: ["reading"], layout: nil),
              after.origin(preserving: anchor, viewport: viewport) == 500,
              after.origin(reflowing: anchor, viewport: viewport) == 550,
              TranscriptRowHost.acceptsWidth(836, proposed: 836.0000000000001),
              !TranscriptRowHost.acceptsWidth(834, proposed: 836.0000000000001) else {
            throw BenchFailure("native reading-offset or accepted-width contract failed")
        }
        PerfHarness.emit(["bench": "check", "geometryContracts": true,
                          "growthOrigin": 500, "reflowOrigin": 550,
                          "roundedWidthAccepted": true, "staleWidthRejected": true])
    }

    private func performMenuAction(_ title: String, in menu: NSMenu) -> Bool {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for (index, item) in menu.items.enumerated() {
            if item.title == title {
                PerfHarness.emit(["bench": "menuAction", "title": title,
                                  "enabled": item.isEnabled, "available": item.action != nil])
            }
            if item.title == title, item.isEnabled, item.action != nil {
                menu.performActionForItem(at: index)
                return true
            }
            if let submenu = item.submenu, performMenuAction(title, in: submenu) { return true }
        }
        return false
    }

    private func check(_ interaction: BenchPlan.Interaction, producer: GestureProducer, window: NSWindow,
                       scrollView: NSScrollView, stream: BenchStream?) async throws {
        guard let container = scrollView as? AppKitTranscriptContainer else { throw BenchFailure("missing native container") }
        switch interaction {
        case .horizontalDisplacement:
            guard let rowID = overflowRowID else { throw BenchFailure("horizontal displacement requires its overflow fixture") }
            let deadline = ContinuousClock.now + .seconds(10)
            var controls: [NSScrollView] = []
            while controls.count != 2 {
                controls = container.hostedRowForBench(id: rowID).map { overflowingScrollers(in: $0) } ?? []
                guard ContinuousClock.now < deadline else { throw BenchFailure("overflow fixture must expose both code and table scrollers") }
                if controls.count != 2 { try await Task.sleep(for: .milliseconds(16)) }
            }
            for (index, control) in controls.enumerated() {
                guard let document = control.documentView,
                      document.bounds.width - control.contentView.bounds.width >= 200 else {
                    throw BenchFailure("fixture control \(index) lacks visible, guaranteed horizontal overflow")
                }
                control.contentView.scroll(to: NSPoint(x: 100, y: control.contentView.bounds.minY))
                control.reflectScrolledClipView(control.contentView)
                let before = control.contentView.bounds.minX
                let visible = control.contentView.visibleRect
                guard visible.width > 1, visible.height > 1, abs(before - 100) <= 1 else {
                    throw BenchFailure("fixture control \(index) has no visible interior wheel target")
                }
                let verticalBefore = container.contentView.bounds.minY
                let local = control.contentView.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
                let point = window.convertPoint(toScreen: local)
                let input = GestureProducer(gestures: [],
                    point: CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y),
                    window: window, delivery: .app, origin: CACurrentMediaTime(), period: 1.0 / 120)
                try input.deliver(vertical: 0, horizontal: -80, scroll: 1, momentum: 0)
                try input.deliver(vertical: 0, horizontal: -80, scroll: 2, momentum: 0)
                try input.deliver(vertical: 0, horizontal: 0, scroll: 4, momentum: 0)
                try await Task.sleep(for: .milliseconds(200))
                let after = control.contentView.bounds.minX
                let verticalAfter = container.contentView.bounds.minY
                PerfHarness.emit(["bench": "check", "interaction": interaction.rawValue, "control": index,
                    "rowID": rowID, "offsetBefore": before, "offsetAfter": after,
                    "verticalBefore": verticalBefore, "verticalAfter": verticalAfter])
                let current = container.hostedRowForBench(id: rowID).map { overflowingScrollers(in: $0) } ?? []
                guard current.contains(where: { $0 === control }), after - before >= 20,
                      abs(verticalAfter - verticalBefore) <= 1 else {
                    throw BenchFailure("horizontal wheel failed to displace fixture control \(index) independently of the transcript")
                }
            }
        case .composerTyping:
            guard let screen = workspace.selectedScreen else { throw BenchFailure("composer screen is missing") }
            try await ComposerTypingBench.run(screen: screen, window: window)
        case .composerEditing:
            try await ComposerEditingBench.run(window: window)
        case .narrowZoom:
            guard let stream, plan.stream?.kind == .paragraph, (plan.stream?.seconds ?? 0) >= 8,
                  NSApp.mainMenu != nil else { throw BenchFailure("narrow-zoom requires a paragraph stream and the app menu") }
            try await stream.run(started: .now)
            try await Task.sleep(for: .milliseconds(200))
            guard let rowID = await stream.rowID() else { throw BenchFailure("narrow-zoom has no canonical paragraph row") }
            container.navigate(.pageUp)
            var acknowledged = false
            container.alignRow(rowID, anchor: .center, animated: false) { acknowledged = true }
            try await Task.sleep(for: .milliseconds(200))
            guard acknowledged, let initial = container.readingPositionForBench(), initial.scale == 1,
                  initial.rowID == rowID, initial.offset > 0, initial.height > scrollView.contentView.bounds.height else {
                throw BenchFailure("narrow-zoom did not reach a settled tall row at actual size")
            }
            defer {
                if let menu = NSApp.mainMenu { _ = performMenuAction("Actual Size", in: menu) }
            }
            for (action, expectedScale) in [("Zoom In", CGFloat(1.1)), ("Actual Size", CGFloat(1))] {
                guard let before = container.readingPositionForBench(), let menu = NSApp.mainMenu,
                      performMenuAction(action, in: menu) else {
                    throw BenchFailure("narrow-zoom could not invoke the app zoom command")
                }
                try await Task.sleep(for: .milliseconds(500))
                guard let after = container.readingPositionForBench() else { throw BenchFailure("narrow-zoom lost its drawn anchor") }
                let displacement = (after.fraction - before.fraction) * after.height
                PerfHarness.emit(["bench": "check", "interaction": interaction.rawValue,
                                  "scaleBefore": before.scale, "scaleAfter": after.scale,
                                  "widthBefore": before.width, "widthAfter": after.width,
                                  "heightBefore": before.height, "heightAfter": after.height,
                                  "relativeDisplacement": displacement, "reflowPending": after.reflowPending])
                guard after.rowID == before.rowID, abs(after.width - before.width) < 0.001,
                      abs(after.height - before.height) > 1, abs(after.scale - expectedScale) < 0.001,
                      abs(displacement) <= 1, !after.reflowPending, !container.isFollowingLatest() else {
                    throw BenchFailure("viewport-limited zoom lost the relative reading point")
                }
            }
        case .tracking:
            guard let stream, container.isFollowingLatest() else { throw BenchFailure("tracking check requires streaming from latest") }
            try producer.deliver(0, scroll: 128, momentum: 0)
            try await stream.run(started: .now)
            try await Task.sleep(for: .milliseconds(150))
            let gapDuringTracking = scrollView.documentView.map { $0.bounds.maxY - $0.visibleRect.maxY } ?? .infinity
            try producer.deliver(0, scroll: 8, momentum: 0)
            try await Task.sleep(for: .milliseconds(100))
            let follows = container.isFollowingLatest()
            PerfHarness.emit(["bench": "check", "interaction": interaction.rawValue,
                              "gapDuringTracking": gapDuringTracking, "followsAfterCancellation": follows])
            guard abs(gapDuringTracking) <= 1, follows else { throw BenchFailure("motionless tracking lost latest during growth") }
        case .readingGrowth:
            guard let stream, plan.stream?.kind == .paragraph, (plan.stream?.seconds ?? 0) >= 8,
                  container.isFollowingLatest() else { throw BenchFailure("reading-growth requires a paragraph stream of at least eight seconds") }
            async let streaming: Void = stream.run(started: .now)
            try await Task.sleep(for: .seconds(5))
            guard let rowID = await stream.rowID() else { throw BenchFailure("reading-growth has no canonical streaming row") }
            container.navigate(.pageUp)
            var acknowledged = false
            container.alignRow(rowID, anchor: .center, animated: false) { acknowledged = true }
            try await Task.sleep(for: .milliseconds(200))
            guard acknowledged, !container.isFollowingLatest(), let before = container.readingPositionForBench(),
                  before.rowID == rowID, before.offset > 0 else {
                throw BenchFailure("reading-growth did not reach the interior of a drawn row")
            }
            try await streaming
            try await Task.sleep(for: .milliseconds(200))
            guard let after = container.readingPositionForBench() else { throw BenchFailure("reading-growth lost its drawn anchor") }
            let displacement = after.offset - before.offset
            PerfHarness.emit(["bench": "check", "interaction": interaction.rawValue,
                              "sameRow": before.rowID == after.rowID, "offsetBefore": before.offset,
                              "offsetAfter": after.offset, "displacement": displacement,
                              "follows": container.isFollowingLatest()])
            guard before.rowID == after.rowID, abs(displacement) <= 1, !container.isFollowingLatest() else {
                throw BenchFailure("same-width tail growth displaced earlier text")
            }
        case .tableSelection:
            guard let stream, let kind = plan.stream?.kind, kind == .wideTable || kind == .wideTableThenProse,
                  (plan.stream?.seconds ?? 0) >= 8 else { throw BenchFailure("table-selection requires a wide-table stream of at least eight seconds") }
            async let streaming: Void = stream.run(started: .now)
            try await Task.sleep(for: .seconds(2))
            guard let rowID = await stream.rowID(), let host = container.hostedRowForBench(id: rowID),
                  let table = overflowingScroller(in: host), let document = table.documentView else {
                throw BenchFailure("wide table has no current overflowing horizontal owner")
            }
            let offset = min(200, (document.bounds.width - table.contentView.bounds.width) / 2)
            table.contentView.scroll(to: NSPoint(x: offset, y: table.contentView.bounds.minY))
            table.reflectScrolledClipView(table.contentView)
            try await Task.sleep(for: .milliseconds(200))
            guard abs(table.contentView.bounds.minX - offset) <= 1 else {
                throw BenchFailure("native table offset was not established")
            }
            try await streaming
            try await Task.sleep(for: .milliseconds(200))
            let current = container.hostedRowForBench(id: rowID).flatMap { overflowingScroller(in: $0) }
            let after = current?.contentView.bounds.minX ?? -1
            PerfHarness.emit(["bench": "check", "interaction": interaction.rawValue,
                              "streamKind": kind.rawValue, "sameScroller": current === table,
                              "offsetBefore": offset, "offsetAfter": after])
            guard current === table, abs(offset - after) <= 1 else {
                throw BenchFailure("table selection transition replaced or reset the horizontal owner")
            }
        case .cancelledMomentum:
            let outsideLocation = NSPoint(x: window.frame.width / 2, y: 30)
            guard !container.contentView.bounds.contains(container.contentView.convert(outsideLocation, from: nil)) else {
                throw BenchFailure("outside wheel fixture intersects the transcript")
            }
            let location = window.convertPoint(toScreen: outsideLocation)
            let outside = GestureProducer(gestures: [], point: CGPoint(x: location.x,
                y: (NSScreen.screens.first?.frame.height ?? 0) - location.y), window: window,
                delivery: .app, origin: 0, period: 1 / 120)
            for start in GestureStart.allCases {
                for navigation: TranscriptScrollHalt.Navigation in [.end, .pageUp] {
                    try await beginGesture(start, producer: producer, outside: outside, container: container)
                    try producer.deliver(80, scroll: 2, momentum: 0)
                    try producer.deliver(vertical: 20, horizontal: 21, scroll: 2, momentum: 0)
                    try producer.deliver(0, scroll: 4, momentum: 0)
                    try producer.deliver(40, scroll: 0, momentum: 1)
                    try producer.deliver(vertical: 20, horizontal: 21, scroll: 0, momentum: 2)
                    try await Task.sleep(for: .milliseconds(100))
                    container.navigate(navigation)
                    try await Task.sleep(for: .milliseconds(100))
                    let deadline = ContinuousClock.now + .seconds(10)
                    while !container.isLayoutReadyForBench || (navigation == .end
                        && scrollView.documentView.map { abs($0.bounds.maxY - $0.visibleRect.maxY) > 1 } != false) {
                        guard ContinuousClock.now < deadline else {
                            throw BenchFailure("transcript navigation did not settle after \(navigation), start=\(start)")
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard let document = scrollView.documentView,
                          let anchor = document.subviews.filter({ $0.frame.height > 0 && $0.frame.intersects(document.visibleRect) })
                            .min(by: { $0.frame.minY < $1.frame.minY }) else {
                        throw BenchFailure("transcript navigation has no visible anchor row")
                    }
                    let gapBefore = document.bounds.maxY - document.visibleRect.maxY
                    let anchorYBefore = anchor.frame.minY - document.visibleRect.minY
                    let dropped = PerfBuild.counters["wheel.dropDrain", default: 0]
                    try outside.deliver(vertical: 20, horizontal: 21, scroll: 0, momentum: 2)
                    try outside.deliver(0, scroll: 0, momentum: 3)
                    try await Task.sleep(for: .milliseconds(100))
                    let gapAfter = document.bounds.maxY - document.visibleRect.maxY
                    let anchorYAfter = anchor.frame.minY - document.visibleRect.minY
                    let anchorDeltaPixels = abs(anchorYAfter - anchorYBefore) * window.backingScaleFactor
                    let drained = PerfBuild.counters["wheel.dropDrain", default: 0] - dropped
                    PerfHarness.emit(["bench": "check", "interaction": interaction.rawValue,
                                      "start": start.rawValue,
                                      "navigation": String(describing: navigation),
                                      "gapBeforeOutsideMomentum": gapBefore, "gapAfterOutsideMomentum": gapAfter,
                                      "gapChange": gapAfter - gapBefore,
                                      "anchorYBefore": anchorYBefore, "anchorYAfter": anchorYAfter,
                                      "anchorDeltaPixels": anchorDeltaPixels,
                                      "anchorRetained": anchor.superview === document,
                                      "drainedOutsideEvents": drained])
                    guard drained == 2 else {
                        throw BenchFailure("cancelled momentum escaped outside the transcript after \(navigation), start=\(start)")
                    }
                    switch navigation {
                    case .end:
                        guard abs(gapBefore) <= 1, abs(gapAfter) <= 1 else {
                            throw BenchFailure("End lost latest after cancelled momentum, start=\(start)")
                        }
                    case .pageUp:
                        guard gapBefore > 1, anchor.superview === document, anchorDeltaPixels <= 1 else {
                            throw BenchFailure("Page Up reading anchor moved after cancelled momentum, start=\(start)")
                        }
                    case .pageDown, .beginning: break
                    }
                }
            }
            for start in GestureStart.allCases {
                try await beginGesture(start, producer: producer, outside: outside, container: container)
                if start == .outside { try outside.deliver(vertical: 0, horizontal: 80, scroll: 2, momentum: 0) }
                let horizontal = PerfBuild.counters["wheel.horizontal", default: 0]
                let vertical = PerfBuild.counters["wheel.pass", default: 0]
                try producer.deliver(vertical: 0, horizontal: 80, scroll: 2, momentum: 0)
                try producer.deliver(vertical: 21, horizontal: 20, scroll: 2, momentum: 0)
                try producer.deliver(vertical: 0, horizontal: 80, scroll: 2, momentum: 0)
                guard PerfBuild.counters["wheel.horizontal", default: 0] == horizontal + 3,
                      PerfBuild.counters["wheel.pass", default: 0] == vertical,
                      let changedTarget = producer.hitTarget(), changedTarget !== container else {
                    throw BenchFailure("horizontal continuation changed direction, start=\(start)")
                }
                try producer.deliver(0, scroll: 4, momentum: 0)
                container.haltScrolling()
                let momentumHorizontal = PerfBuild.counters["wheel.horizontal", default: 0]
                let momentumVertical = PerfBuild.counters["wheel.pass", default: 0]
                let dropped = PerfBuild.counters["wheel.dropDrain", default: 0]
                try producer.deliver(vertical: 0, horizontal: 80, scroll: 0, momentum: 1)
                try producer.deliver(vertical: 21, horizontal: 20, scroll: 0, momentum: 2)
                try producer.deliver(vertical: 0, horizontal: 80, scroll: 0, momentum: 2)
                guard let momentumTarget = producer.hitTarget(), momentumTarget !== container else {
                    throw BenchFailure("horizontal continuation momentum selected the transcript, start=\(start)")
                }
                try outside.deliver(vertical: 0, horizontal: 80, scroll: 0, momentum: 2)
                try outside.deliver(0, scroll: 0, momentum: 3)
                guard PerfBuild.counters["wheel.horizontal", default: 0] == momentumHorizontal + 3,
                      PerfBuild.counters["wheel.pass", default: 0] == momentumVertical,
                      PerfBuild.counters["wheel.dropDrain", default: 0] == dropped else {
                    throw BenchFailure("halt intercepted horizontal continuation momentum, start=\(start)")
                }
                PerfHarness.emit(["bench": "check", "interaction": "horizontal-continuation", "start": start.rawValue,
                                  "changedSamples": 3, "momentumSamples": 3, "drainedEvents": 0,
                                  "changedTarget": String(describing: type(of: changedTarget)),
                                  "momentumTarget": String(describing: type(of: momentumTarget))])
            }
            try outside.deliver(20, scroll: 1, momentum: 0)
            try outside.deliver(20, scroll: 2, momentum: 0)
            try outside.deliver(0, scroll: 4, momentum: 0)
            container.haltScrolling()
            let unownedDrained = PerfBuild.counters["wheel.dropDrain", default: 0]
            let unownedPassed = PerfBuild.counters["wheel.outside", default: 0]
            try outside.deliver(20, scroll: 0, momentum: 1)
            try outside.deliver(20, scroll: 0, momentum: 2)
            try outside.deliver(0, scroll: 0, momentum: 3)
            guard PerfBuild.counters["wheel.dropDrain", default: 0] == unownedDrained,
                  PerfBuild.counters["wheel.outside", default: 0] == unownedPassed + 3 else {
                throw BenchFailure("halt intercepted unrelated outside momentum")
            }
            PerfHarness.emit(["bench": "check", "interaction": "unowned-momentum", "passedOutsideEvents": 3,
                              "drainedEvents": 0])
            try producer.deliver(0, scroll: 1, momentum: 0)
            container.haltScrolling()
            let beforeUnrelated = PerfBuild.counters["wheel.dropDrain", default: 0]
            try outside.deliver(0, scroll: 1, momentum: 0)
            try outside.deliver(20, scroll: 2, momentum: 0)
            try outside.deliver(0, scroll: 4, momentum: 0)
            guard PerfBuild.counters["wheel.dropDrain", default: 0] == beforeUnrelated else {
                throw BenchFailure("cancelled transcript gesture swallowed unrelated input")
            }
            try producer.deliver(0, scroll: 1, momentum: 0)
            guard let zeroStartTarget = producer.hitTarget(), zeroStartTarget !== container else {
                throw BenchFailure("zero gesture start was intercepted by the vertical transcript")
            }
            let horizontal = PerfBuild.counters["wheel.horizontal", default: 0]
            let vertical = PerfBuild.counters["wheel.pass", default: 0]
            try producer.deliver(vertical: 20, horizontal: 21, scroll: 2, momentum: 0)
            try producer.deliver(vertical: 21, horizontal: 20, scroll: 2, momentum: 0)
            guard PerfBuild.counters["wheel.horizontal", default: 0] - horizontal == 2,
                  PerfBuild.counters["wheel.pass", default: 0] == vertical else {
                throw BenchFailure("horizontal gesture was routed to the vertical transcript")
            }
            try producer.deliver(0, scroll: 8, momentum: 0)
            guard let cancellationTarget = producer.hitTarget(), cancellationTarget !== container else {
                throw BenchFailure("horizontal cancellation was intercepted by the vertical transcript")
            }
            try producer.deliver(vertical: 0, horizontal: 20, scroll: 1, momentum: 0)
            try producer.deliver(0, scroll: 4, momentum: 0)
            try producer.deliver(0, scroll: 0, momentum: 1)
            try producer.deliver(0, scroll: 0, momentum: 3)
            guard let momentumTarget = producer.hitTarget(), momentumTarget !== container else {
                throw BenchFailure("horizontal momentum termination was intercepted by the vertical transcript")
            }
            PerfHarness.emit(["bench": "check", "interaction": interaction.rawValue,
                              "horizontalClassification": true, "zeroStartTarget": String(describing: type(of: zeroStartTarget)),
                              "cancellationTarget": String(describing: type(of: cancellationTarget)),
                              "momentumTarget": String(describing: type(of: momentumTarget))])
            try checkOtherWindow(producer: producer, window: window, container: container)
        }
    }

    private enum GestureStart: String, CaseIterable { case inside, outside, resumed }

    private func beginGesture(_ start: GestureStart, producer: GestureProducer, outside: GestureProducer,
                              container: AppKitTranscriptContainer) async throws {
        switch start {
        case .inside: try producer.deliver(0, scroll: 1, momentum: 0)
        case .outside: try outside.deliver(0, scroll: 1, momentum: 0)
        case .resumed:
            try producer.deliver(0, scroll: 1, momentum: 0)
            try producer.deliver(20, scroll: 2, momentum: 0)
            container.suspend()
            container.resume()
            let deadline = ContinuousClock.now + .seconds(10)
            while !container.isLayoutReadyForBench {
                guard ContinuousClock.now < deadline else { throw BenchFailure("resumed transcript layout did not settle") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func checkOtherWindow(producer: GestureProducer, window: NSWindow,
                                  container: AppKitTranscriptContainer) throws {
        let other = GestureCheckWindow(contentRect: NSRect(x: window.frame.maxX + 12, y: window.frame.minY,
                                                          width: 240, height: 160),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFront(nil)
        defer { other.close() }
        let location = other.convertPoint(toScreen: NSPoint(x: 120, y: 80))
        let otherProducer = GestureProducer(gestures: [], point: CGPoint(x: location.x,
            y: (NSScreen.screens.first?.frame.height ?? 0) - location.y), window: other,
            delivery: .app, origin: 0, period: 1 / 120)
        for drains in [false, true] {
            try producer.deliver(0, scroll: 1, momentum: 0)
            try producer.deliver(20, scroll: 2, momentum: 0)
            try producer.deliver(0, scroll: 4, momentum: 0)
            if drains { container.haltScrolling() }
            let received = other.wheelEvents
            let dropped = PerfBuild.counters["wheel.dropDrain", default: 0]
            try otherProducer.deliver(0, scroll: 1, momentum: 0)
            try otherProducer.deliver(vertical: 0, horizontal: 20, scroll: 2, momentum: 0)
            let horizontal = PerfBuild.counters["wheel.horizontal", default: 0]
            try producer.deliver(vertical: 21, horizontal: 20, scroll: 2, momentum: 0)
            guard other.wheelEvents - received == 2,
                  PerfBuild.counters["wheel.dropDrain", default: 0] == dropped,
                  PerfBuild.counters["wheel.horizontal", default: 0] == horizontal + 1,
                  let target = producer.hitTarget(), target !== container else {
                throw BenchFailure("fresh gesture in another window inherited transcript ownership")
            }
            try producer.deliver(0, scroll: 8, momentum: 0)
            PerfHarness.emit(["bench": "check", "interaction": "cross-window-fresh",
                              "previouslyDraining": drains, "otherWindowEvents": other.wheelEvents - received,
                              "target": String(describing: type(of: target))])
        }
    }
}

private final class GestureCheckWindow: NSWindow {
    private(set) var wheelEvents = 0

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel { wheelEvents += 1 }
        super.sendEvent(event)
    }
}

/// Generates trackpad-like continuous scroll events on a dedicated thread paced
/// by wall-clock time, so a stalled main thread cannot slow the input down. Each
/// event queues on the main queue, as HID events queue on the app's event port,
/// and is dispatched through `NSApp.sendEvent`.
private final class GestureProducer: @unchecked Sendable {
    private enum Step {
        case drag(velocity: Double, seconds: Double, eased: Bool)
        case momentum(velocity: Double)
        case pause(seconds: Double)
    }

    private static let momentumDecayPerSecond = pow(0.998, 1000.0)
    private static let momentumStopVelocity = 60.0

    private let steps: [Step]
    private let localPoint: NSPoint
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let windowNumberField: UInt32 = 51
    private let screenLocation: CGPoint
    private let windowEventLocation: CGPoint
    private let setWindowLocation: SetWindowLocation?
    private let windowNumber: Int
    private weak var window: NSWindow?
    private let delivery: BenchPlan.Delivery
    private let origin: Double
    private let period: Double
    private let lock = NSLock()
    private var records: [[Double]] = []
    private var carry = 0.0
    private var failure: String?

    @MainActor init(gestures: [BenchGesture], point: CGPoint, window: NSWindow, delivery: BenchPlan.Delivery,
                    origin: Double, period: Double) {
        steps = gestures.flatMap { gesture -> [Step] in
            var steps: [Step] = [.drag(velocity: gesture.velocity, seconds: gesture.dragSeconds, eased: gesture.eased)]
            if gesture.momentum { steps.append(.momentum(velocity: gesture.velocity)) }
            if gesture.pauseSeconds > 0 { steps.append(.pause(seconds: gesture.pauseSeconds)) }
            return steps
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let local = window.convertPoint(fromScreen: NSPoint(x: point.x, y: primaryHeight - point.y))
        localPoint = local
        screenLocation = point
        windowNumber = window.windowNumber
        let setWindowLocation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
            .map { unsafeBitCast($0, to: SetWindowLocation.self) }
        self.setWindowLocation = setWindowLocation
        let probeOrigin = setWindowLocation.flatMap { set in
            Self.event(pixels: 0, horizontal: 0, scroll: 0, momentum: 0, at: point, windowNumber: window.windowNumber, timestamp: 0)
                .flatMap { probe in set(probe, .zero); return NSEvent(cgEvent: probe)?.locationInWindow }
        } ?? .zero
        windowEventLocation = CGPoint(x: local.x - probeOrigin.x, y: probeOrigin.y - local.y)
        self.window = window
        self.delivery = delivery
        self.origin = origin
        self.period = period
    }

    func run() async throws -> [[Double]] {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { [self] in
                produce()
                DispatchQueue.main.async { [self] in
                    let result = lock.withLock { (failure, records) }
                    if let failure = result.0 { continuation.resume(throwing: BenchFailure(failure)) }
                    else { continuation.resume(returning: result.1) }
                }
            }
            thread.qualityOfService = .userInteractive
            thread.name = "PerfHarness.GestureProducer"
            thread.start()
        }
    }

    private func produce() {
        for (index, step) in steps.enumerated() {
            guard lock.withLock({ failure == nil }) else { return }
            switch step {
            case .drag(let velocity, let seconds, let eased):
                post(0, scroll: 1, momentum: 0, gesture: index)
                stream(seconds: seconds, gesture: index, scroll: 2, momentum: 0) { start, end in
                    guard eased else { return velocity * (end - start) }
                    let travelled = { (time: Double) in velocity * seconds / .pi * (1 - cos(.pi * time / seconds)) }
                    return travelled(end) - travelled(start)
                }
                post(0, scroll: 4, momentum: 0, gesture: index)
            case .momentum(let velocity):
                let decay = log(Self.momentumDecayPerSecond)
                let seconds = log(Self.momentumStopVelocity / abs(velocity)) / decay
                guard seconds > 0 else { continue }
                var first = true
                stream(seconds: seconds, gesture: index, scroll: 0, momentum: 2) { start, end in
                    velocity * (exp(decay * end) - exp(decay * start)) / decay
                } onFirst: { first ? { first = false; return 1 }() : 2 }
                post(0, scroll: 0, momentum: 3, gesture: index)
            case .pause(let seconds):
                Thread.sleep(forTimeInterval: seconds)
            }
        }
    }

    private func stream(seconds: Double, gesture: Int, scroll: Int64, momentum: Int64,
                        distance: (Double, Double) -> Double, onFirst: (() -> Int64)? = nil) {
        let start = nextVsync(after: CACurrentMediaTime()) - period
        var previous = 0.0
        while previous < seconds {
            guard lock.withLock({ failure == nil }) else { return }
            let due = nextVsync(after: CACurrentMediaTime())
            let wait = due - CACurrentMediaTime()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let elapsed = min(due - start, seconds)
            let pixels = distance(previous, elapsed)
            previous = elapsed
            post(pixels, scroll: scroll, momentum: onFirst?() ?? momentum, gesture: gesture, intended: due)
        }
    }

    private func nextVsync(after time: Double) -> Double {
        origin + (((time - origin) / period).rounded(.down) + 1) * period
    }

    private func post(_ pixels: Double, scroll: Int64, momentum: Int64, gesture: Int, intended: Double? = nil) {
        let total = pixels + carry
        let whole = total.rounded(.towardZero)
        carry = total - whole
        let posted = CACurrentMediaTime()
        let timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let index = lock.withLock {
            records.append([intended ?? posted, posted, whole, Double(scroll), Double(momentum), Double(gesture), 0])
            return records.count - 1
        }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard lock.withLock({ failure == nil }) else { return }
                do { try deliver(whole, horizontal: 0, scroll: scroll, momentum: momentum, timestamp: timestamp) }
                catch { lock.withLock { failure = String(describing: error) } }
            }
            let handled = CACurrentMediaTime()
            lock.withLock { records[index][6] = handled }
        }
    }

    @MainActor
    func deliver(_ pixels: Double, scroll: Int64, momentum: Int64) throws {
        try deliver(vertical: pixels, horizontal: 0, scroll: scroll, momentum: momentum)
    }

    @MainActor
    func deliver(vertical: Double, horizontal: Double, scroll: Int64, momentum: Int64) throws {
        try deliver(vertical, horizontal: horizontal, scroll: scroll, momentum: momentum,
                    timestamp: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    @MainActor
    func hitTarget() -> NSView? {
        guard let frame = window?.contentView?.superview else { return nil }
        return frame.hitTest(frame.convert(localPoint, from: nil))
    }

    @MainActor
    private func deliver(_ pixels: Double, horizontal: Double, scroll: Int64, momentum: Int64, timestamp: UInt64) throws {
        guard let window,
              let event = Self.event(pixels: pixels, horizontal: horizontal, scroll: scroll, momentum: momentum, at: screenLocation,
                                     windowNumber: windowNumber, timestamp: timestamp),
              let setWindowLocation else {
            throw BenchFailure("Cannot construct the wheel event, resolve CGEventSetWindowLocation or find the target window")
        }
        setWindowLocation(event, windowEventLocation)
        guard let nsEvent = NSEvent(cgEvent: event) else { throw BenchFailure("Cannot convert the wheel event") }
        guard nsEvent.window === window else {
            throw BenchFailure("Wheel event resolved window \(nsEvent.window?.windowNumber ?? 0), expected \(windowNumber); delivery=\(delivery.rawValue)")
        }
        guard hypot(nsEvent.locationInWindow.x - localPoint.x, nsEvent.locationInWindow.y - localPoint.y) <= 1 else {
            throw BenchFailure("Wheel event located at \(nsEvent.locationInWindow), expected \(localPoint) in the window; delivery=\(delivery.rawValue)")
        }
        switch delivery {
        case .app:
            let setCurrentEvent = NSSelectorFromString("_setCurrentEvent:")
            guard NSApp.responds(to: setCurrentEvent) else {
                throw BenchFailure("NSApplication no longer responds to _setCurrentEvent:")
            }
            NSApp.perform(setCurrentEvent, with: nsEvent)
            NSApp.sendEvent(nsEvent)
        case .send: window.sendEvent(nsEvent)
        case .queue: NSApp.postEvent(nsEvent, atStart: false)
        }
    }

    private static func event(pixels: Double, horizontal: Double, scroll: Int64, momentum: Int64, at point: CGPoint, windowNumber: Int,
                              timestamp: UInt64) -> CGEvent? {
        guard let windowField = CGEventField(rawValue: windowNumberField),
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(pixels), wheel2: Int32(horizontal), wheel3: 0) else { return nil }
        event.location = point
        event.timestamp = timestamp
        event.setIntegerValueField(windowField, value: Int64(windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scroll)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pixels))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: pixels)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(horizontal))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: horizontal)
        return event
    }
}

/// Main-run-loop pacing while the gestures run: one row per display-link
/// callback with the main thread's busy time since the previous callback, and
/// every clip-view bounds change with its time.
@MainActor
fileprivate final class FrameMeter: NSObject {
    private struct BusyInterval {
        let frame: Int
        let start: UInt64
        let end: UInt64
    }

    private static let intervalCapacity = 65_536
    private let window: NSWindow
    private var scrollView: NSScrollView
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var busyStart: UInt64?
    private var busy = 0.0
    private var longestBusy = 0.0
    private var boundsChanges = 0
    private var rows: [[Double]] = []
    private var bounds: [[Double]] = []
    private var marks: [Int: [String: Any]] = [:]
    private var counterSampler = PerfBuild.CounterSampler(start: PerfBuild.Counters())
    private var startCounters: [String: Int] = [:]
    private var busyIntervals: [BusyInterval] = []
    private var droppedBusyIntervals = 0
    private var startedNanoseconds: UInt64 = 0
    private(set) var started = 0.0

    init(window: NSWindow, scrollView: NSScrollView) {
        self.window = window
        self.scrollView = scrollView
        super.init()
    }

    func start() {
        PerfBuild.resetSpans()
        busyIntervals.reserveCapacity(Self.intervalCapacity)
        let counterSnapshot = PerfBuild.counterSnapshot
        startCounters = counterSnapshot.values
        startedNanoseconds = PerfBuild.uptimeNanoseconds()
        started = Double(startedNanoseconds) / 1e9
        counterSampler = PerfBuild.CounterSampler(start: counterSnapshot)
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.observe(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        busyStart = PerfBuild.uptimeNanoseconds()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        let fps = Float(window.screen?.maximumFramesPerSecond ?? 120)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func observeScrollView(_ next: NSScrollView) {
        guard next !== scrollView else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView = next
        next.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: next.contentView)
    }

    private func observe(_ activity: CFRunLoopActivity) {
        let now = PerfBuild.uptimeNanoseconds()
        if activity == .afterWaiting {
            busyStart = now
        } else if let start = busyStart {
            let elapsed = Double(now - start) / 1e9
            busy += elapsed
            longestBusy = max(longestBusy, elapsed)
            recordBusyInterval(from: start, to: now)
            busyStart = nil
        }
    }

    private func recordBusyInterval(from start: UInt64, to end: UInt64) {
        guard busyIntervals.count < Self.intervalCapacity else {
            droppedBusyIntervals += 1
            return
        }
        busyIntervals.append(.init(frame: rows.count, start: start, end: end))
    }

    @objc private func boundsChanged(_ notification: Notification) {
        boundsChanges += 1
        bounds.append([CACurrentMediaTime(), scrollView.contentView.bounds.origin.y])
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = PerfBuild.uptimeNanoseconds()
        var pending = busy
        var longest = longestBusy
        if let start = busyStart {
            let elapsed = Double(now - start) / 1e9
            pending += elapsed
            longest = max(longest, elapsed)
            recordBusyInterval(from: start, to: now)
            busyStart = now
        }
        rows.append([link.timestamp, link.targetTimestamp, Double(now) / 1e9, pending * 1000, longest * 1000,
                     scrollView.contentView.bounds.origin.y, Double(boundsChanges),
                     scrollView.documentView?.frame.height ?? 0])
        busy = 0
        longestBusy = 0
        boundsChanges = 0
        if let deltas = counterSampler.tick(generation: PerfBuild.counterGeneration, read: { PerfBuild.counterSnapshot }) {
            marks[rows.count - 1] = ["t": link.timestamp, "d": deltas]
        }
    }

    func firstVsync() async throws -> (Double, Double) {
        while true {
            if let row = rows.first, row[1] > row[0] { return (row[0], row[1] - row[0]) }
            try await Task.sleep(for: .milliseconds(4))
        }
    }

    func work(from start: Double, until end: Double) -> [String: Any] {
        let intervals = busyIntervals.compactMap { interval -> Double? in
            let lower = max(start, Double(interval.start) / 1e9)
            let upper = min(end, Double(interval.end) / 1e9)
            return upper > lower ? (upper - lower) * 1_000 : nil
        }
        let gaps = zip(rows, rows.dropFirst()).filter { $0.1[0] > start && $0.0[0] < end }
        let missed = gaps.reduce(0) { total, pair in
            total + max(0, Int(((pair.1[0] - pair.0[0]) / (pair.1[1] - pair.1[0])).rounded()) - 1)
        }
        return ["mainThreadBusyToReadyMs": intervals.reduce(0, +),
                "longestMainPassToReadyMs": intervals.max() ?? 0, "missedVsyncsToReady": missed]
    }

    func finish() -> (frames: [[Double]], bounds: [[Double]], marks: [[String: Any]], started: Double,
                      ended: Double, spans: [[String: Any]], spanRecording: [String: Any], counterWindow: PerfBuild.CounterWindow) {
        let ended = PerfBuild.uptimeNanoseconds()
        let endCounters = PerfBuild.counters
        stop()
        let spans = summarizeSpans(until: ended)
        let reportedMarks = marks.sorted { $0.key < $1.key }.map { $0.value }
        return (rows, bounds, reportedMarks, started, Double(ended) / 1e9, spans.table, spans.recording, PerfBuild.CounterWindow(start: startCounters, end: endCounters))
    }

    func stop() {
        link?.invalidate()
        link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func summarizeSpans(until ended: UInt64) -> (table: [[String: Any]], recording: [String: Any]) {
        let snapshot = PerfBuild.spanSnapshot()
        var durations: [String: [Double]] = [:]
        var mainDurations: [String: Double] = [:]
        var frameSpans = Array(repeating: [(name: String, duration: Double, overlap: Double, main: Bool)](), count: rows.count)
        var retained = 0
        for record in snapshot.records {
            let start = max(record.startNanoseconds, startedNanoseconds)
            let end = min(record.endNanoseconds, ended)
            guard end > start else { continue }
            retained += 1
            let name = record.name.description
            let duration = Double(end - start) / 1e6
            durations[name, default: []].append(duration)
            if record.isMainThread { mainDurations[name, default: 0] += duration }
            var lower = 0
            var upper = busyIntervals.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if busyIntervals[middle].end <= start { lower = middle + 1 }
                else { upper = middle }
            }
            var overlaps: [Int: UInt64] = [:]
            while lower < busyIntervals.count, busyIntervals[lower].start < end {
                let interval = busyIntervals[lower]
                if interval.frame < rows.count {
                    overlaps[interval.frame, default: 0] += min(end, interval.end) - max(start, interval.start)
                }
                lower += 1
            }
            for (frame, overlap) in overlaps where overlap > 0 {
                frameSpans[frame].append((name, duration, Double(overlap) / 1e6, record.isMainThread))
                frameSpans[frame].sort {
                    if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
                    if $0.duration != $1.duration { return $0.duration > $1.duration }
                    return $0.name < $1.name
                }
                if frameSpans[frame].count > 5 { frameSpans[frame].removeLast() }
            }
        }
        let table: [[String: Any]] = durations.map { name, values in
            let sorted = values.sorted()
            let total = values.reduce(0, +)
            let main = mainDurations[name, default: 0]
            return ["name": name, "count": values.count, "totalMs": total,
                    "p50Ms": sorted[Int(ceil(Double(sorted.count) * 0.5)) - 1],
                    "p95Ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
                    "maxMs": sorted[sorted.count - 1], "mainThreadMs": main, "mainThreadShare": main / total]
        }
        for frame in frameSpans.indices where marks[frame] != nil || !frameSpans[frame].isEmpty {
            var mark = marks[frame] ?? ["t": rows[frame][0], "d": [String: Int]()]
            mark["spans"] = frameSpans[frame].map {
                ["name": $0.name, "durationMs": $0.duration, "overlapMs": $0.overlap, "mainThread": $0.main] as [String: Any]
            }
            marks[frame] = mark
        }
        return (table, ["capacity": snapshot.capacity, "retained": retained, "overwritten": snapshot.overwritten,
                        "busyIntervalCapacity": Self.intervalCapacity, "busyIntervalsDropped": droppedBusyIntervals,
                        "truncated": snapshot.overwritten > 0 || droppedBusyIntervals > 0])
    }
}

/// Captures the app's own window through ScreenCaptureKit's current-process
/// content, which needs no screen-recording consent. Every delivered frame's
/// status and WindowServer display time are kept; `video` also writes a movie.
fileprivate final class WindowRecorder: NSObject, SCStreamOutput, SCRecordingOutputDelegate, @unchecked Sendable {
    private let stream: SCStream
    private var movie: SCRecordingOutput?
    private let url: URL?
    private let queue = DispatchQueue(label: "PerfHarness.WindowRecorder", qos: .userInitiated)
    private let lock = NSLock()
    private var samples: [[Double]] = []
    private var frameSize: [Int] = []
    private var finished: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var didFinish = false
    private var startedAt = 0.0
    private let ticksToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    private init(stream: SCStream, movie: SCRecordingOutputConfiguration?) {
        self.stream = stream
        url = movie?.outputURL
        super.init()
        self.movie = movie.map { SCRecordingOutput(configuration: $0, delegate: self) }
    }

    @MainActor static func start(window: NSWindow, video: URL?) async throws -> WindowRecorder {
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw BenchFailure("ScreenCaptureKit does not list the transcript window")
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        let fps = window.screen?.maximumFramesPerSecond ?? 60
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 8
        configuration.showsCursor = false
        let movie = video.map { url in
            let movie = SCRecordingOutputConfiguration()
            movie.outputURL = url
            movie.outputFileType = .mov
            movie.videoCodecType = .hevc
            return movie
        }
        let recorder = WindowRecorder(stream: SCStream(filter: filter, configuration: configuration, delegate: nil), movie: movie)
        try recorder.attach()
        try await recorder.stream.startCapture()
        recorder.startedAt = CACurrentMediaTime()
        return recorder
    }

    private func attach() throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if let movie { try stream.addRecordingOutput(movie) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = info[.status] as? Int else { return }
        let display = (info[.displayTime] as? UInt64).map { Double($0) * ticksToSeconds } ?? 0
        let received = CACurrentMediaTime()
        let size = sampleBuffer.imageBuffer.map { [CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)] }
        lock.withLock {
            if let size, status == SCFrameStatus.complete.rawValue { frameSize = size }
            if samples.count < 65_536 { samples.append([display, received, Double(status)]) }
        }
    }

    func finish() async throws -> [String: Any] {
        let stopped = CACurrentMediaTime()
        try await stream.stopCapture()
        if movie != nil {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if let failure {
                        continuation.resume(throwing: failure)
                    } else if didFinish {
                        continuation.resume()
                    } else {
                        finished = continuation
                    }
                }
            }
        }
        return ["path": url?.path ?? NSNull(), "startedAt": startedAt, "stoppedAt": stopped,
                "frames": lock.withLock { samples }, "frameSize": lock.withLock { frameSize }]
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        lock.withLock {
            failure = error
            finished?.resume(throwing: error)
            finished = nil
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock {
            didFinish = true
            finished?.resume()
            finished = nil
        }
    }
}
#endif
