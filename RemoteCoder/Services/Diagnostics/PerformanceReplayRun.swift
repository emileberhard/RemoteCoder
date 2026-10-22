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
    private var consumed = false
    private var stopped = false

    private init(scenario: PerformanceReplayScenario, hash: String, server: PerformanceReplayServer,
                 workspace: ChatWorkspaceModel) {
        self.scenario = scenario
        self.hash = hash
        self.server = server
        self.workspace = workspace
    }

    @concurrent private static func fixture(_ url: URL) async throws -> (PerformanceReplayScenario, String) {
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1_048_576 else { throw PerformanceReplayScenario.Failure.invalidScenario("fixture exceeds 16 MiB") }
        let scenario = try JSONDecoder().decode(PerformanceReplayScenario.self, from: data)
        try scenario.validate()
        return (try scenario.rebased(to: Date.now.timeIntervalSince1970), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func prepare(_ url: URL, workspace: ChatWorkspaceModel) async throws -> PerformanceReplayRun {
        guard AppStorageScope.isOfflineReplay, AppStorageScope.current.isBenchmark,
              workspace.settings.hosts.isEmpty else {
            throw PerformanceReplayScenario.Failure.invalidScenario("launch with -rcPerfOffline and no configured hosts")
        }
        let (scenario, hash) = try await fixture(url)
        try PerformanceReplayHTTP.install(scenario.httpResponses ?? [:])
        let server = try PerformanceReplayServer(scenario: scenario)
        let run = PerformanceReplayRun(scenario: scenario, hash: hash, server: server, workspace: workspace)
        do {
            let port = try await server.start()
            let host = GatewayHostConfiguration(id: run.hostID, name: "Offline replay", hostname: "127.0.0.1",
                port: Int(port), authToken: "offline-replay", transport: .trustedNetwork)
            guard workspace.settings.upsert(host) else { throw PerformanceReplayScenario.Failure.invalidScenario("could not install isolated host") }
            workspace.reconcileHosts()
            await workspace.bootstrap()
            guard let first = scenario.conversations.first?.thread.objectValue?["id"]?.stringValue else {
                throw PerformanceReplayScenario.Failure.invalidScenario("missing initial conversation")
            }
            try await PerformanceReplayNavigation(workspace: workspace, hostID: run.hostID).open(first)
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
        let metrics = PerformanceReplayMetrics()
        let interval = Self.signposter.beginInterval("ReplayJourney", id: Self.signposter.makeSignpostID(), "\(self.scenario.name, privacy: .public)")
        let start = ContinuousClock.now
        do {
            async let delivery = Self.deliver(scenario.events, server: server, start: start)
            let actions = try await PerformanceReplayNavigation(workspace: workspace, hostID: hostID).performActions(scenario.actions, start: start)
            let delivered = try await delivery
            try await Task.sleep(until: start + .seconds(scenario.duration), clock: .continuous)
            Self.signposter.endInterval("ReplayJourney", interval)
            var report = metrics.finish()
            report["scenario"] = scenario.name
            report["mode"] = "offlineReplay"
            report["fixtureSHA256"] = hash
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
            report["blockedVisualLoads"] = PerformanceReplayHTTP.blockedVisualLoads
            report["valid"] = report["activeThroughout"] as? Bool == true && report["conservedEnergy"] as? Bool == false
                && (report["frames"] as? Int ?? 0) > 0 && diagnostics.failures.isEmpty && diagnostics.unsupported.isEmpty && http.missing.isEmpty
                && http.blockedExternal == 0 && PerformanceReplayHTTP.blockedVisualLoads == 0
                && report["frameIntervalsOverflowed"] as? Bool == false
                && !verification.isEmpty && verification.allSatisfy { $0["matches"] as? Bool == true }
            report["cleanupFailures"] = await stop()
            report["serverFailures"] = await server.diagnostics().failures
            report["valid"] = report["valid"] as? Bool == true && (report["cleanupFailures"] as? [String])?.isEmpty == true
                && (report["serverFailures"] as? [String])?.isEmpty == true
            return report
        } catch {
            Self.signposter.endInterval("ReplayJourney", interval)
            _ = metrics.finish()
            _ = await stop()
            throw error
        }
    }

    static func calibrate(_ url: URL, workspace: ChatWorkspaceModel, hostID: UUID, threads: [String]) async throws -> [String: Any] {
        let (scenario, hash) = try await fixture(url)
        let sources = scenario.actions.filter { $0.kind == .open }.map(\.threadID)
        let ordered = sources.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !AppStorageScope.isOfflineReplay, threads.count == ordered.count else {
            throw PerformanceReplayScenario.Failure.invalidScenario("live calibration requires one real thread per replay stream")
        }
        let mapping = Dictionary(uniqueKeysWithValues: zip(ordered, threads))
        let actions = try scenario.actions.map { action in
            guard let thread = mapping[action.threadID] else { throw PerformanceReplayScenario.Failure.invalidScenario("unmapped action") }
            return PerformanceReplayScenario.Action(at: action.at, kind: action.kind, threadID: thread, message: action.message)
        }
        let navigation = PerformanceReplayNavigation(workspace: workspace, hostID: hostID)
        let metrics = PerformanceReplayMetrics()
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
        let completed = scenario.events.compactMap { event -> (thread: String, turn: String, item: String, text: String)? in
            guard let fields = event.frame.objectValue, fields["method"] == .string("item/completed"),
                  let params = fields["params"]?.objectValue, let item = params["item"]?.objectValue,
                  item["type"] == .string("agentMessage"), let id = item["id"]?.stringValue,
                  let thread = params["threadId"]?.stringValue, let turn = params["turnId"]?.stringValue,
                  let text = item["text"]?.stringValue else { return nil }
            return (thread, turn, id, text)
        }
        var verified: [[String: Any]] = []
        guard let model = workspace.model(for: hostID) else { return [] }
        for (thread, entries) in Dictionary(grouping: completed, by: \.thread).sorted(by: { $0.key < $1.key }) {
            try await PerformanceReplayNavigation(workspace: workspace, hostID: hostID).open(thread)
            let session = await model.conversations.existingSession(threadID: thread)
            let snapshot = await session?.snapshot()
            for entry in entries {
                let message = snapshot?.messages.first { $0.canonicalItemID == entry.item && $0.canonicalTurnID == entry.turn }
                verified.append(["threadID": thread, "itemID": entry.item, "matches": message?.text == entry.text && message?.isStreaming == false,
                    "expectedSHA256": SHA256.hash(data: Data(entry.text.utf8)).map { String(format: "%02x", $0) }.joined(),
                    "actualSHA256": message.map { SHA256.hash(data: Data($0.text.utf8)).map { String(format: "%02x", $0) }.joined() } as Any? ?? NSNull()])
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
            guard ContinuousClock.now < deadline else { throw PerformanceReplayScenario.Failure.invalidScenario("conversation did not load: \(threadID)") }
            try await Task.sleep(for: .milliseconds(16))
        }
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
                    guard let commands = window.performanceActions?() else {
                        throw PerformanceReplayScenario.Failure.invalidScenario("window commands unavailable")
                    }
                    let requested = !commands.isSidebarOpen
                    commands.run(.toggleSidebar)
                    let deadline = ContinuousClock.now + .seconds(2)
                    while window.performanceActions?()?.isSidebarOpen != requested {
                        guard ContinuousClock.now < deadline else {
                            throw PerformanceReplayScenario.Failure.invalidScenario("sidebar presentation did not change")
                        }
                        try await Task.sleep(for: .milliseconds(16))
                    }
                    presentation = ["sidebarBefore": commands.isSidebarOpen, "sidebarAfter": requested]
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
