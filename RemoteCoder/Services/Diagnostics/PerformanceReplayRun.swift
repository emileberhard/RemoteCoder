#if RC_PERF_HARNESS
import CryptoKit
import Foundation
import OSLog
import Synchronization
import SwiftUI

nonisolated final class PerformanceReplayCredentials: GatewayCredentialStorage {
    private let data = Mutex<Data?>(nil)
    func read() -> Data? { data.withLock { $0 } }
    func write(_ data: Data) { self.data.withLock { $0 = data } }
}

@MainActor
final class PerformanceReplayRun {
    static let signposter = OSSignposter(subsystem: "RemoteCoder", category: .pointsOfInterest)
    private let scenario: PerformanceReplayScenario
    private let hash: String
    private let server: PerformanceReplayServer
    private let workspace: ChatWorkspaceModel
    private let hostID = ChatMessage.deterministicID(for: "performance-replay-host")
    private var preparedState: [String: Any] = [:]
    private var consumed = false
    private var stopped = false

    private init(scenario: PerformanceReplayScenario, hash: String, server: PerformanceReplayServer,
                 workspace: ChatWorkspaceModel) {
        self.scenario = scenario
        self.hash = hash
        self.server = server
        self.workspace = workspace
    }

    @concurrent static func fixture(_ url: URL) async throws -> (PerformanceReplayScenario, String, URL) {
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1_048_576 else { throw PerformanceReplayScenario.Failure.invalidScenario("fixture exceeds 16 MiB") }
        let scenario = try JSONDecoder().decode(PerformanceReplayScenario.self, from: data)
        try scenario.validate()
        return (scenario, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), url.deletingLastPathComponent())
    }

    @concurrent static func preparedFixture(_ url: URL) async throws -> (PerformanceReplayScenario, String, URL) {
        let (scenario, hash, root) = try await fixture(url)
        let destination = root.appending(path: "prepared")
        return (try scenario.prepared(to: Date.now.timeIntervalSince1970, root: root, destination: destination), hash, destination)
    }

    static func prepare(_ url: URL, workspace: ChatWorkspaceModel) async throws -> PerformanceReplayRun {
        guard AppStorageScope.isOfflineReplay, AppStorageScope.current.isBenchmark,
              workspace.settings.hosts.isEmpty else {
            throw PerformanceReplayScenario.Failure.invalidScenario("launch with -rcPerfOffline and no configured hosts")
        }
        let (scenario, hash, fixtureRoot) = try await preparedFixture(url)
        try PerformanceReplayHTTP.install(scenario.httpResponses ?? [:], telemetryDirectory: url.deletingLastPathComponent().appending(path: "telemetry"))
        let server = try PerformanceReplayServer(scenario: scenario, fixtureRoot: fixtureRoot)
        let run = PerformanceReplayRun(scenario: scenario, hash: hash, server: server, workspace: workspace)
        do {
            let port = try await server.start()
            let host = GatewayHostConfiguration(id: run.hostID, name: "Offline replay", hostname: "127.0.0.1",
                port: Int(port), authToken: "offline-replay", transport: .trustedNetwork)
            guard workspace.settings.upsert(host) else { throw PerformanceReplayScenario.Failure.invalidScenario("could not install isolated host") }
            workspace.reconcileHosts()
            await workspace.bootstrap()
            guard let model = workspace.model(for: run.hostID) else {
                throw PerformanceReplayScenario.Failure.invalidScenario("isolated host did not bootstrap")
            }
            let navigation = PerformanceReplayNavigation(workspace: workspace, hostID: run.hostID)
            try await navigation.setSidebarOpen(false)
            run.preparedState = try await PerformanceReplayPreparation.prepare(scenario, model: model, progressURL: url.deletingLastPathComponent().appending(path: "preparation-progress.json"))
            guard let first = scenario.conversations.first?.thread.objectValue?["id"]?.stringValue else {
                throw PerformanceReplayScenario.Failure.invalidScenario("missing initial conversation")
            }
            try await navigation.open(first)
            try await navigation.setSidebarOpen(false)
            return run
        } catch {
            await run.stop()
            throw error
        }
    }

    func run() async throws -> [String: Any] {
        guard !consumed else { throw PerformanceReplayScenario.Failure.invalidScenario("a replay run can only execute once") }
        consumed = true
        let preparation = await server.diagnostics()
        guard let model = workspace.model(for: hostID) else {
            throw PerformanceReplayScenario.Failure.invalidScenario("prepared host disappeared")
        }
        let beforeOwner = await model.conversations.performanceReplayCheckpointInventory()
        let metrics = PerformanceReplayMetrics(workspace: workspace, fixtureWork: server.work)
        let interval = Self.signposter.beginInterval("ReplayJourney", id: Self.signposter.makeSignpostID(), "\(self.scenario.name, privacy: .public)")
        let start = ContinuousClock.now
        do {
            async let delivery = Self.deliver(scenario.events, server: server, start: start)
            let actions = try await PerformanceReplayNavigation(workspace: workspace, hostID: hostID).performActions(scenario.actions, start: start)
            let delivered = try await delivery
            try await Task.sleep(until: start + .seconds(scenario.duration), clock: .continuous)
            Self.signposter.endInterval("ReplayJourney", interval)
            var report = measuredReport(metrics)
            report["preMeasurementOwner"] = beforeOwner
            report["postMeasurementOwner"] = await model.conversations.performanceReplayCheckpointInventory()
            report["scheduledDuration"] = scenario.duration
            report["actions"] = actions
            report["deliveries"] = delivered
            report["appliedFrames"] = delivered.count
            report["sentNotifications"] = delivered.reduce(0) { $0 + Int($1["recipients", default: 0]) }
            report["scheduleOverrunMs"] = max(0, (report["seconds"] as? Double ?? scenario.duration) - scenario.duration) * 1000
            let measured = await server.diagnostics()
            let verification = try await verifyFinalContent()
            report["finalContent"] = verification
            let diagnostics = await server.diagnostics()
            report["preparationRPCRequests"] = preparation.requests
            report["rpcRequests"] = measured.requests.reduce(into: [String: Int]()) {
                $0[$1.key] = $1.value - preparation.requests[$1.key, default: 0]
            }
            report["verificationRPCRequests"] = diagnostics.requests.reduce(into: [String: Int]()) {
                $0[$1.key] = $1.value - measured.requests[$1.key, default: 0]
            }
            report["unsupportedRPCs"] = diagnostics.unsupported
            report["unsupportedRequests"] = try diagnostics.unsupportedRequests.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
            report["serverFailures"] = diagnostics.failures
            let http = PerformanceReplayHTTP.diagnostics()
            report["httpRequests"] = http.requests
            report["uncapturedHTTP"] = http.missing
            report["blockedExternalHTTP"] = http.blockedExternal
            report["omittedSiteIconFetches"] = PerformanceReplayHTTP.omittedSiteIconFetches
            report["omittedVisualFetches"] = PerformanceReplayHTTP.omittedVisualFetches
            report["blockedVisualLoads"] = PerformanceReplayHTTP.blockedVisualLoads
            report["valid"] = report["activeThroughout"] as? Bool == true && report["conservedEnergy"] as? Bool == false
                && (report["frames"] as? Int ?? 0) > 0 && diagnostics.failures.isEmpty && diagnostics.unsupported.isEmpty && http.missing.isEmpty
                && http.blockedExternal == 0 && PerformanceReplayHTTP.blockedVisualLoads == 0
                && report["frameIntervalsOverflowed"] as? Bool == false
                && !verification.isEmpty && verification.allSatisfy { $0["matches"] as? Bool == true }
            report["cleanupFailures"] = await stop()
            report["telemetryFiles"] = PerformanceReplayHTTP.telemetryCapture.files
            report["telemetryCaptureFailures"] = PerformanceReplayHTTP.telemetryCapture.failures
            report["serverFailures"] = await server.diagnostics().failures
            report["valid"] = report["valid"] as? Bool == true && (report["cleanupFailures"] as? [String])?.isEmpty == true
                && (report["serverFailures"] as? [String])?.isEmpty == true
            return report
        } catch {
            Self.signposter.endInterval("ReplayJourney", interval)
            var report = measuredReport(metrics)
            report["valid"] = false
            report["preMeasurementOwner"] = beforeOwner
            report["postMeasurementOwner"] = await model.conversations.performanceReplayCheckpointInventory()
            report["error"] = String(describing: error)
            let diagnostics = await server.diagnostics()
            report["preparationRPCRequests"] = preparation.requests
            report["rpcRequests"] = diagnostics.requests.reduce(into: [String: Int]()) {
                $0[$1.key] = $1.value - preparation.requests[$1.key, default: 0]
            }
            report["unsupportedRPCs"] = diagnostics.unsupported
            report["serverFailures"] = diagnostics.failures
            report["cleanupFailures"] = await stop()
            report["telemetryFiles"] = PerformanceReplayHTTP.telemetryCapture.files
            report["telemetryCaptureFailures"] = PerformanceReplayHTTP.telemetryCapture.failures
            return report
        }
    }

    private func measuredReport(_ metrics: PerformanceReplayMetrics) -> [String: Any] {
        var report = metrics.finish()
        report["scenario"] = scenario.name
        report["mode"] = "offlineReplay"
        report["workloadVersion"] = scenario.version
        report["preparationContractVersion"] = 2
        report["preparation"] = preparedState
        report["fixtureSHA256"] = hash
        if let evidence = scenario.captureSummary?.objectValue?["idleEvidence"],
           let encoded = try? JSONEncoder().encode(evidence) {
            report["captureAuthority"] = try? JSONSerialization.jsonObject(with: encoded)
        }
        return report
    }

    static func calibrate(_ url: URL, workspace: ChatWorkspaceModel, hostID: UUID, threads: [String]) async throws -> [String: Any] {
        let (scenario, hash, _) = try await fixture(url)
        let actionThreads = Set(scenario.actions.map(\.threadID))
        let ordered = scenario.conversations.compactMap { conversation -> String? in
            guard let threadID = conversation.thread.objectValue?["id"]?.stringValue,
                  actionThreads.contains(threadID) else { return nil }
            return threadID
        }
        guard !AppStorageScope.isOfflineReplay, threads.count == ordered.count else {
            throw PerformanceReplayScenario.Failure.invalidScenario("live calibration requires one real thread per replay stream")
        }
        let mapping = Dictionary(uniqueKeysWithValues: zip(ordered, threads))
        let actions = try scenario.actions.map { action in
            guard let thread = mapping[action.threadID] else { throw PerformanceReplayScenario.Failure.invalidScenario("unmapped action") }
            return PerformanceReplayScenario.Action(at: action.at, kind: action.kind, threadID: thread, message: action.message)
        }
        let navigation = PerformanceReplayNavigation(workspace: workspace, hostID: hostID)
        guard let first = threads.first else {
            throw PerformanceReplayScenario.Failure.invalidScenario("live calibration has no initial conversation")
        }
        try await navigation.open(first)
        try await navigation.setSidebarOpen(false)
        let metrics = PerformanceReplayMetrics(workspace: workspace, fixtureWork: nil)
        let interval = signposter.beginInterval("ReplayJourney", id: signposter.makeSignpostID(), "live calibration")
        do {
            let start = ContinuousClock.now
            let receipts = try await navigation.performActions(actions, start: start)
            try await Task.sleep(until: start + .seconds(scenario.duration), clock: .continuous)
            signposter.endInterval("ReplayJourney", interval)
            var report = metrics.finish()
            report["actions"] = receipts
            report["mode"] = "liveCalibration"
            report["fixtureSHA256"] = hash
            report["scenario"] = scenario.name
            report["windowValid"] = report["activeThroughout"] as? Bool == true && report["conservedEnergy"] as? Bool == false
                && (report["frames"] as? Int ?? 0) > 0 && report["frameIntervalsOverflowed"] as? Bool == false
            report["valid"] = false
            return report
        } catch {
            _ = metrics.finish()
            signposter.endInterval("ReplayJourney", interval)
            throw error
        }
    }

    private func verifyFinalContent() async throws -> [[String: Any]] {
        var verified: [[String: Any]] = []
        guard let model = workspace.model(for: hostID) else { return [] }
        for conversation in scenario.conversations {
            guard let thread = conversation.thread.objectValue?["id"]?.stringValue else { continue }
            let entries = PerformanceReplayVerification.completions(threadID: thread, events: scenario.events)
            guard !entries.isEmpty else { continue }
            try await PerformanceReplayNavigation(workspace: workspace, hostID: hostID).open(thread)
            guard let session = await model.conversations.existingSession(threadID: thread) else {
                throw PerformanceReplayScenario.Failure.invalidScenario("verification session is unavailable")
            }
            let snapshot = await session.snapshot()
            var checks = PerformanceReplayVerification.checks(entries, messages: snapshot.messages, window: nil)
            let header = try await model.historyService.readHeader(threadID: thread)
            var read = await session.beginHistoryRead()
            var history = try await model.historyService.openTail(header: header, base: nil, bypassCache: true)
            var remaining = Dictionary(uniqueKeysWithValues: entries.map { ($0.identity, $0) })
            var archived: [PerformanceReplayVerification.Identity: (text: String, complete: Bool)] = [:]
            var actualText: [PerformanceReplayVerification.Identity: String] = [:]
            var seen = Set<String>()
            let maximumPages = conversation.itemCount + scenario.events.count + 1
            while true {
                let projected = await session.merge(history, read: read)
                for (identity, matches) in PerformanceReplayVerification.checks(entries, messages: projected.messages, window: history.window) {
                    checks[identity] = (checks[identity] ?? true) && matches
                }
                for message in projected.messages {
                    if let turn = message.canonicalTurnID, let item = message.canonicalItemID {
                        actualText[.init(turn: turn, item: item)] = message.text
                    }
                }
                for turn in history.window.turns {
                    for entry in turn.entries {
                        let identity = PerformanceReplayVerification.Identity(turn: entry.turnId, item: entry.item.id)
                        guard remaining[identity] != nil,
                              case .agentMessage(_, let text, _, _, _) = entry.item else { continue }
                        archived[identity] = (text, entry.isComplete == true)
                        remaining.removeValue(forKey: identity)
                    }
                }
                guard !remaining.isEmpty, let cursor = history.window.older else { break }
                guard seen.insert(cursor).inserted, seen.count <= maximumPages else {
                    throw PerformanceReplayScenario.Failure.invalidScenario("verification history cursor did not advance")
                }
                read = await session.beginHistoryRead()
                history = try await model.historyService.page(header: history.header, window: history.window,
                    direction: .desc, priority: .foreground)
            }
            for entry in entries {
                let message = snapshot.messages.first { $0.canonicalItemID == entry.identity.item && $0.canonicalTurnID == entry.identity.turn }
                let stored = archived[entry.identity]
                verified.append(["threadID": thread, "itemID": entry.identity.item,
                    "matches": checks[entry.identity] == true && stored?.text == entry.text && stored?.complete == true,
                    "retained": message != nil, "historyVerified": stored != nil,
                    "expectedSHA256": SHA256.hash(data: Data(entry.text.utf8)).map { String(format: "%02x", $0) }.joined(),
                    "actualSHA256": actualText[entry.identity].map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } as Any? ?? NSNull()])
            }
        }
        return verified
    }

    @concurrent private static func deliver(_ events: [PerformanceReplayScenario.Event], server: PerformanceReplayServer,
                                            start: ContinuousClock.Instant) async throws -> [[String: Double]] {
        var receipts: [[String: Double]] = []
        for event in events {
            try await Task.sleep(until: start + .seconds(event.at), clock: .continuous)
            try Task.checkCancellation()
            let before = start.duration(to: .now) / .seconds(1)
            let recipients = try await server.deliver(event.frame)
            receipts.append(["scheduled": event.at, "started": before, "recipients": Double(recipients),
                "finished": start.duration(to: .now) / .seconds(1), "latenessMs": max(0, before - event.at) * 1000])
        }
        return receipts
    }

    @discardableResult func stop() async -> [String] {
        guard !stopped else { return [] }
        stopped = true
        workspace.teardown()
        var failures: [String] = []
        for model in workspace.models {
            if !(await model.retire()) { failures.append("Model retirement failed") }
        }
        await server.stop()
        await DiagnosticsOutbox.shared.stopPumping()
        await PerformanceReplayHTTP.retainPendingTelemetry(at: AppStorageScope.current.applicationSupport.appending(path: "RemoteCoder/app-logs"))
        do { try await AppStorageScope.current.discardBenchmark() }
        catch { failures.append("Benchmark storage cleanup: " + error.localizedDescription) }
        return failures
    }
}
@MainActor
private struct PerformanceReplayNavigation {
    let workspace: ChatWorkspaceModel
    let hostID: UUID
    func open(_ threadID: String) async throws {
        _ = workspace.switchConversation(to: ConversationAddress(hostID: hostID, threadID: threadID))
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            try Task.checkCancellation()
            if let screen = workspace.selectedScreen, screen.openThreadID == threadID,
               screen.loadingTranscriptID == nil, screen.alert == nil, !screen.messages.isEmpty {
                if !AppStorageScope.isOfflineReplay || threadID.hasPrefix("claude_") { return }
                if workspace.model(for: hostID)?.observation.state(of: threadID) == .live { return }
            }
            guard ContinuousClock.now < deadline else {
                let screen = workspace.selectedScreen
                throw PerformanceReplayScenario.Failure.invalidScenario("conversation load timed out selected=\(screen?.openThreadID == threadID) loading=\(screen?.loadingTranscriptID != nil) messages=\(screen?.messages.count ?? 0) alert=\(screen?.alert != nil) live=\(workspace.model(for: hostID)?.observation.state(of: threadID) == .live)")
            }
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    @discardableResult
    func setSidebarOpen(_ requested: Bool) async throws -> (before: Bool, after: Bool) {
        let window = workspace.keyWindow
        let deadline = ContinuousClock.now + .seconds(2)
        while window.performanceSidebar == nil {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw PerformanceReplayScenario.Failure.invalidScenario("window commands unavailable")
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        guard let commands = window.performanceSidebar else {
            throw PerformanceReplayScenario.Failure.invalidScenario("window commands unavailable")
        }
        let previous = commands.isOpen
        if previous != requested { commands.toggle() }
        while window.performanceSidebar?.isOpen != requested || window.isHistoryDrawerOpen != requested {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw PerformanceReplayScenario.Failure.invalidScenario("sidebar presentation did not change")
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        return (previous, requested)
    }

    func performActions(_ actions: [PerformanceReplayScenario.Action], start: ContinuousClock.Instant) async throws -> [[String: Any]] {
        var receipts: [[String: Any]] = []
        for action in actions {
            try await Task.sleep(until: start + .seconds(action.at), clock: .continuous)
            try Task.checkCancellation()
            let before = start.duration(to: .now) / .seconds(1)
            let span = PerformanceReplayRun.signposter.beginInterval("ReplayAction", id: PerformanceReplayRun.signposter.makeSignpostID(), "\(action.kind.rawValue, privacy: .public) \(action.threadID, privacy: .public)")
            var presentation: [String: Any] = [:]
            do {
                switch action.kind {
                case .open:
                    try await open(action.threadID)
                case .toggleSidebar:
                    let window = workspace.keyWindow
                    guard let commands = window.performanceSidebar else {
                        throw PerformanceReplayScenario.Failure.invalidScenario("window commands unavailable")
                    }
                    let transition = try await setSidebarOpen(!commands.isOpen)
                    presentation = ["sidebarBefore": transition.before, "sidebarAfter": transition.after]
                case .scroll:
                    guard let screen = workspace.selectedScreen, screen.openThreadID == action.threadID,
                          let index = action.message, screen.messages.indices.contains(index) else {
                        throw PerformanceReplayScenario.Failure.invalidScenario("scroll target unavailable")
                    }
                    screen.requestTranscriptRow(ChatStreamItem.message(screen.messages[index]).id, anchor: .center, motion: .animated)
                }
                PerformanceReplayRun.signposter.endInterval("ReplayAction", span)
            } catch {
                PerformanceReplayRun.signposter.endInterval("ReplayAction", span)
                throw error
            }
            receipts.append(["kind": action.kind.rawValue, "threadID": action.threadID, "scheduled": action.at,
                "started": before, "finished": start.duration(to: .now) / .seconds(1),
                "latenessMs": max(0, before - action.at) * 1000, "messageCount": workspace.selectedScreen?.messages.count ?? 0]
                .merging(presentation) { _, new in new })
        }
        return receipts
    }

}
#endif
