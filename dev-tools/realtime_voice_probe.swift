import AVFoundation
import CryptoKit
import Darwin
import Foundation

final class ProbeLog: @unchecked Sendable {
    private let startedAt = ContinuousClock.now
    private let handle: FileHandle
    let path: String

    init() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/remote-coder/voice-probes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let filename = "probe-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(8)).jsonl"
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RealtimeProbeError.invalidJSON("creating probe log")
        }
        handle = try FileHandle(forWritingTo: url)
        path = url.path
        setbuf(stdout, nil)
        setbuf(stderr, nil)
    }

    deinit {
        try? handle.close()
    }

    func event(_ phase: String, fields: [String: Any] = [:]) {
        var object = fields
        object["elapsedMs"] = milliseconds(startedAt.duration(to: .now))
        object["phase"] = phase
        object["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        let bytes = Data(line.utf8)
        try? handle.write(contentsOf: bytes)
        print(line, terminator: "")
    }

    private func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}

@MainActor
struct RPCConnection {
    let socket: URLSessionWebSocketTask
    let log: ProbeLog
    private(set) var nextID = 1
    private(set) var bufferedNotifications: [[String: Any]] = []
    private var pendingFrame: Task<URLSessionWebSocketTask.Message, any Error>?

    init(socket: URLSessionWebSocketTask, log: ProbeLog) {
        self.socket = socket
        self.log = log
    }

    mutating func notify(_ method: String, params: [String: Any]) async throws {
        try await send(["method": method, "params": params])
        log.event("rpc.notification.sent", fields: ["method": method])
    }

    mutating func call(
        _ method: String,
        params: [String: Any],
        timeout: Duration = .seconds(60)
    ) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let start = ContinuousClock.now
        let deadline = start.advanced(by: timeout)
        try await send(["id": id, "method": method, "params": params])
        log.event("rpc.request.sent", fields: ["id": id, "method": method])

        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw RealtimeProbeError.timedOut(method) }
            let object = try await receiveObject(timeout: remaining, phase: method)
            if let responseID = object["id"] as? Int, responseID == id {
                let components = start.duration(to: .now).components
                let elapsedMs = components.seconds * 1_000
                    + components.attoseconds / 1_000_000_000_000_000
                if let error = object["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? String(describing: error)
                    log.event("rpc.response.error", fields: [
                        "elapsedMsForRequest": elapsedMs,
                        "id": id,
                        "method": method,
                        "message": message,
                    ])
                    throw RealtimeProbeError.rpc(method: method, message: message)
                }
                log.event("rpc.response.received", fields: [
                    "elapsedMsForRequest": elapsedMs,
                    "id": id,
                    "method": method,
                ])
                return object["result"] as? [String: Any] ?? [:]
            }
            if object["method"] is String {
                guard bufferedNotifications.count < maxBufferedNotifications else {
                    throw RealtimeProbeError.notificationOverflow(method)
                }
                bufferedNotifications.append(object)
            }
        }
    }

    mutating func nextNotification(timeout: Duration) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        if !bufferedNotifications.isEmpty {
            return bufferedNotifications.removeFirst()
        }
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw RealtimeProbeError.timedOut("waiting for notification") }
            let object = try await receiveObject(timeout: remaining, phase: "waiting for notification")
            if object["method"] is String {
                return object
            }
        }
    }

    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeProbeError.invalidJSON("encoding a websocket frame")
        }
        try await socket.send(.string(text))
    }

    private mutating func receiveObject(timeout: Duration, phase: String) async throws -> [String: Any] {
        // A timeout stops waiting, not URLSession's receive. Keep that same
        // receive so the next RPC cannot lose its response to an abandoned wait.
        let pending = pendingFrame ?? Task { [socket] in try await socket.receive() }
        pendingFrame = pending
        let frame = try await receiveWebSocketMessage(
            from: pending,
            timeout: timeout,
            phase: phase
        )
        pendingFrame = nil

        let data: Data
        switch frame {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default:
            throw RealtimeProbeError.invalidJSON("decoding an unknown websocket frame")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealtimeProbeError.invalidJSON("decoding a websocket frame")
        }
        if let method = object["method"] as? String {
            var fields = ["method": method]
            if let params = object["params"] as? [String: Any],
               let threadID = params["threadId"] as? String
            {
                fields["threadHash"] = shortHash(threadID)
            }
            log.event("rpc.notification.received", fields: fields)
        }
        return object
    }
}

private func receiveWebSocketMessage(
    from pendingFrame: Task<URLSessionWebSocketTask.Message, any Error>,
    timeout: Duration,
    phase: String
) async throws -> URLSessionWebSocketTask.Message {
    let gate = WebSocketReceiveGate()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            Task {
                gate.finish(await pendingFrame.result)
            }
            gate.installTimeout(Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                gate.finish(.failure(RealtimeProbeError.timedOut(phase)))
            })
        }
    } onCancel: {
        gate.finish(.failure(CancellationError()))
    }
}

private final class WebSocketReceiveGate: @unchecked Sendable {
    typealias Message = URLSessionWebSocketTask.Message

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Message, any Error>?
    private var completedResult: Result<Message, any Error>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Message, any Error>) {
        let result: Result<Message, any Error>? = lock.withLock {
            if let completedResult {
                return completedResult
            }
            self.continuation = continuation
            return nil
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    func installTimeout(_ task: Task<Void, Never>) {
        let alreadyCompleted = lock.withLock {
            guard completedResult == nil else { return true }
            timeoutTask = task
            return false
        }
        if alreadyCompleted {
            task.cancel()
        }
    }

    func finish(_ result: Result<Message, any Error>) {
        let completion: (
            CheckedContinuation<Message, any Error>?,
            Task<Void, Never>?
        )? = lock.withLock {
            guard completedResult == nil else { return nil }
            completedResult = result
            let completion = (continuation, timeoutTask)
            continuation = nil
            timeoutTask = nil
            return completion
        }
        completion?.1?.cancel()
        completion?.0?.resume(with: result)
    }
}

func loadGatewayEnvironment() throws -> [String: String] {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".remote-coder/codex-gateway.env")
    let text = try String(contentsOf: path, encoding: .utf8)
    return Dictionary(uniqueKeysWithValues: text.split(whereSeparator: \.isNewline).compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
            return nil
        }
        return (String(trimmed[..<separator]), String(trimmed[trimmed.index(after: separator)...]))
    })
}

func shortHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
}

@main
@MainActor
struct RealtimeVoiceProbe {
    static func main() async {
        do {
            let log = try ProbeLog()
            log.event("probe.started", fields: ["logPath": log.path])
            do {
                try await run(log: log)
                log.event("probe.completed", fields: ["result": "pass"])
                print("PASS log=\(log.path)")
            } catch {
                log.event("probe.completed", fields: [
                    "error": error.localizedDescription,
                    "result": "fail",
                ])
                fputs("FAIL \(error.localizedDescription) log=\(log.path)\n", stderr)
                exit(1)
            }
        } catch {
            fputs("FAIL unable to create probe log: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(log: ProbeLog) async throws {
        let options = try RealtimeProbeOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let claudeMode = options.claudeMode
        let contextMode = options.contextMode
        let handoffMode = options.handoffMode
        let mediaMode = options.mediaMode
        let fixturePath = options.fixturePath
        if options.silent {
            try await requireSilentAudioRoutes()
            if let fixturePath, !FileManager.default.isReadableFile(atPath: fixturePath) {
                throw RealtimeProbeError.fixturePlaybackFailed("Silent mode requires a cached readable fixture")
            }
        }
        if mediaMode, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw RealtimeProbeError.microphoneUnauthorized
        }
        log.event("probe.mode", fields: [
            "handoff": handoffMode,
            "media": mediaMode,
            "provider": claudeMode ? "claude" : "codex",
            "resumeContext": contextMode,
            "silent": options.silent,
        ])

        let environment = try loadGatewayEnvironment()
        guard let token = environment["RC_CODEX_GATEWAY_AUTH_TOKEN"],
              let port = environment["RC_CODEX_GATEWAY_PORT"]
        else {
            throw RealtimeProbeError.invalidGatewayEnvironment
        }

        var request = URLRequest(url: try options.gatewayURL(port: port))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let urlSession = URLSession(configuration: .ephemeral)
        let socket = urlSession.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        var rpc = RPCConnection(socket: socket, log: log)

        _ = try await rpc.call("initialize", params: [
            "clientInfo": [
                "name": "RemoteCoderProbe",
                "title": "RemoteCoder Realtime Probe",
                "version": "1",
            ],
            "capabilities": ["experimentalApi": true],
        ])
        try await rpc.notify("initialized", params: [:])

        let hostInfo = try await rpc.call("host/info", params: [:])
        let cwd = try options.workingDirectory(homeDirectory: hostInfo["homeDirectory"] as? String)
        let voiceStatus = try await rpc.call("voice/session/status", params: [:])
        if voiceStatus["active"] as? Bool == true {
            throw RealtimeProbeError.voiceSessionBusy
        }

        var threadStartParams: [String: Any] = [
            "cwd": cwd,
            "model": claudeMode ? "claude-sonnet-5" : "gpt-5.6-luna",
            "config": ["model_reasoning_effort": "medium", "model_reasoning_summary": "detailed"],
            "ephemeral": true,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "persistExtendedHistory": false,
            "serviceName": "RemoteCoder Realtime Probe",
        ]
        if claudeMode {
            threadStartParams["provider"] = "claude"
        }
        let threadResponse = try await rpc.call(
            "thread/start",
            params: threadStartParams,
            timeout: .seconds(150)
        )
        guard let thread = threadResponse["thread"] as? [String: Any],
              let threadID = thread["id"] as? String
        else {
            throw RealtimeProbeError.missingThreadID
        }
        log.event("thread.provisional.created", fields: ["threadHash": shortHash(threadID)])

        let webRTC = RealtimeWebRTCSession()
        webRTC.onICEConnectionStateChange = { state in
            log.event("webrtc.iceConnection.changed", fields: ["state": state.rawValue])
        }
        webRTC.onICEGatheringStateChange = { state in
            log.event("webrtc.iceGathering.changed", fields: ["state": state.rawValue])
        }

        var voiceStarted = false
        do {
            _ = try await rpc.call("conversation/marks/update", params: [
                "changes": [["op": "setPurpose", "threadId": threadID, "purpose": "probe"]],
            ])
            if !claudeMode, thread["reasoningEffort"] as? String != "medium" {
                throw RealtimeProbeError.initialSettingsNotApplied(String(describing: thread["reasoningEffort"] ?? "none"))
            }
            if options.silent { try await requireSilentAudioRoutes() }
            let offer = try await webRTC.createOffer(inputEnabled: mediaMode)
            log.event("webrtc.offer.created", fields: [
                "sdpBytes": offer.utf8.count,
                "sdpHash": shortHash(offer),
            ])
            let initialItems = contextMode
                ? RealtimeVoiceConversationHistory.initialItems(from: [
                    RealtimeVoiceHistoryMessage(
                        role: .user,
                        text: "The secret word for this conversation is wombat."
                    ),
                    RealtimeVoiceHistoryMessage(
                        role: .assistant,
                        text: "Understood. I will remember that the secret word is wombat."
                    ),
                ])
                : []
            let initialItemsJSON: [[String: Any]] = initialItems.map { item in
                ["role": item.role.rawValue, "text": item.text]
            }
            log.event("voice.context.prepared", fields: [
                "characters": initialItems.reduce(0) { $0 + $1.text.count },
                "items": initialItems.count,
            ])
            let voiceResponse = try await rpc.call("voice/session/start", params: [
                "conversationThreadId": threadID,
                "realtimeSessionId": "remotecoder-probe-\(threadID)",
                "replaceExistingSession": true,
                "cwd": cwd,
                "model": claudeMode ? "claude-sonnet-5" : "gpt-5.6-luna",
                "effort": "medium",
                "sdp": offer,
                "voice": "cove",
                "initialItems": initialItemsJSON,
            ])
            guard let realtimeThreadID = voiceResponse["realtimeThreadId"] as? String else {
                throw RealtimeProbeError.missingThreadID
            }
            log.event("voice.started", fields: [
                "agentThreadHash": shortHash(threadID),
                "realtimeThreadHash": shortHash(realtimeThreadID),
            ])
            voiceStarted = true

            while true {
                let notification = try await rpc.nextNotification(timeout: .seconds(45))
                guard let method = notification["method"] as? String else { continue }
                if method == "thread/realtime/error" {
                    let params = notification["params"] as? [String: Any]
                    throw RealtimeProbeError.rpc(
                        method: method,
                        message: params?["message"] as? String ?? "unknown realtime error"
                    )
                }
                guard method == "thread/realtime/sdp" else { continue }
                guard let params = notification["params"] as? [String: Any],
                      let answer = params["sdp"] as? String
                else {
                    throw RealtimeProbeError.missingAnswerSDP
                }
                log.event("webrtc.answer.received", fields: [
                    "sdpBytes": answer.utf8.count,
                    "sdpHash": shortHash(answer),
                ])
                try await webRTC.applyAnswer(answer)
                log.event("webrtc.answer.applied")
                try await webRTC.applyAnswer(answer)
                log.event("webrtc.answer.duplicateIgnored")
                break
            }
            try await webRTC.waitUntilConnected(timeout: .seconds(20))
            log.event("webrtc.connected")
            if let fixturePath {
                try await validateMedia(
                    webRTC: webRTC,
                    rpc: &rpc,
                    agentThreadID: threadID,
                    realtimeThreadID: realtimeThreadID,
                    fixturePath: fixturePath,
                    silent: options.silent,
                    expectHandoff: handoffMode,
                    expectedAssistantSubstring: contextMode ? "wombat" : nil,
                    log: log
                )
            }
        } catch {
            let failures = await cleanUp(
                rpc: &rpc, webRTC: webRTC, threadID: threadID, claudeMode: claudeMode,
                voiceStarted: voiceStarted, interruptActiveTurns: true, log: log
            )
            if !failures.isEmpty {
                throw RealtimeProbeError.cleanupFailed("\(error.localizedDescription); \(failures.joined(separator: "; "))")
            }
            throw error
        }

        let failures = await cleanUp(
            rpc: &rpc, webRTC: webRTC, threadID: threadID, claudeMode: claudeMode,
            voiceStarted: true, interruptActiveTurns: false, log: log
        )
        guard failures.isEmpty else {
            throw RealtimeProbeError.cleanupFailed(failures.joined(separator: "; "))
        }
    }

    private static func cleanUp(
        rpc: inout RPCConnection,
        webRTC: RealtimeWebRTCSession,
        threadID: String,
        claudeMode: Bool,
        voiceStarted: Bool,
        interruptActiveTurns: Bool,
        log: ProbeLog
    ) async -> [String] {
        var failures: [String] = []
        func fail(_ step: String, _ error: any Error) {
            failures.append("\(step): \(error.localizedDescription)")
            log.event("cleanup.failed", fields: ["message": error.localizedDescription, "step": step])
        }
        if voiceStarted {
            do {
                _ = try await rpc.call("voice/session/stop", params: [:])
                log.event("voice.stopped")
            } catch {
                fail("voice/session/stop", error)
            }
        }
        if claudeMode {
            if interruptActiveTurns {
                do {
                    let activity = try await rpc.call("daemon/activeTurns", params: [:])
                    let turns = activity["activeTurns"] as? [[String: Any]] ?? []
                    for turn in turns where turn["threadId"] as? String == threadID {
                        guard let turnID = turn["turnId"] as? String else { continue }
                        _ = try await rpc.call(
                            "turn/interrupt",
                            params: ["threadId": threadID, "turnId": turnID]
                        )
                    }
                } catch {
                    fail("interrupt active turns", error)
                }
            }
            do {
                let release = try await rpc.call(
                    "claude/thread/release",
                    params: ["threadId": threadID]
                )
                log.event("thread.testRuntime.released", fields: [
                    "released": release["released"] as? Bool ?? false,
                    "threadHash": shortHash(threadID),
                ])
            } catch {
                fail("claude/thread/release", error)
            }
        } else {
            do {
                _ = try await rpc.call("thread/archive", params: ["threadId": threadID])
                log.event("thread.provisional.archived", fields: ["threadHash": shortHash(threadID)])
            } catch {
                if isMissingRollout(error) {
                    log.event("thread.provisional.notPersisted", fields: [
                        "message": error.localizedDescription,
                        "threadHash": shortHash(threadID),
                    ])
                } else {
                    fail("thread/archive", error)
                }
            }
        }
        webRTC.close()
        return failures
    }

    private static func requireSilentAudioRoutes() async throws {
        for route in ["input", "output"] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["SwitchAudioSource", "-c", "-t", route]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { child in continuation.resume(returning: child.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            let selected = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard status == 0, selected == "BlackHole 2ch" else {
                throw RealtimeProbeError.fixturePlaybackFailed("Silent mode requires BlackHole 2ch on both Mac audio routes")
            }
        }
    }

    private static func validateMedia(
        webRTC: RealtimeWebRTCSession,
        rpc: inout RPCConnection,
        agentThreadID: String,
        realtimeThreadID: String,
        fixturePath: String,
        silent: Bool,
        expectHandoff: Bool,
        expectedAssistantSubstring: String?,
        log: ProbeLog
    ) async throws {
        let before = try await webRTC.mediaStatistics()
        logMediaStatistics(before, phase: "media.stats.before", log: log)

        if silent { try await requireSilentAudioRoutes() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [fixturePath]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { child in
                continuation.resume(returning: child.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: RealtimeProbeError.fixturePlaybackFailed(error.localizedDescription))
            }
        }
        guard status == 0 else {
            throw RealtimeProbeError.fixturePlaybackFailed(
                "afplay exited with status \(status)"
            )
        }
        // BlackHole is both output and microphone; mute before the spoken result
        // can feed back into a second utterance.
        webRTC.setInputEnabled(false)
        log.event("media.fixture.played")
        logMediaStatistics(try await webRTC.mediaStatistics(), phase: "media.stats.afterFixture", log: log)

        var heardUser = false
        var heardAssistant = false
        var tally = DelegationTally()
        var heardAssistantAfterAgentCompletion = false
        var assistantTranscript = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(150))
        while (expectHandoff ? !heardAssistantAfterAgentCompletion : !heardAssistant) {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw RealtimeProbeError.timedOut("validating media") }
            let notification = try await rpc.nextNotification(timeout: min(remaining, .seconds(40)))
            guard let method = notification["method"] as? String else { continue }
            let params = notification["params"] as? [String: Any]
            let expectedThreadID = method.hasPrefix("thread/realtime/")
                ? realtimeThreadID
                : agentThreadID
            if let notificationThreadID = params?["threadId"] as? String,
               notificationThreadID != expectedThreadID
            {
                log.event("rpc.notification.ignored", fields: [
                    "method": method,
                    "threadHash": shortHash(notificationThreadID),
                ])
                continue
            }
            if method == "thread/realtime/error" {
                throw RealtimeProbeError.rpc(
                    method: method,
                    message: params?["message"] as? String ?? "unknown realtime error"
                )
            }
            if let observation = try tally.record(method: method, params: params) {
                switch observation {
                case .handoffRequested:
                    log.event("handoff.requested", fields: ["count": tally.handoffCount])
                case .agentStarted:
                    log.event("handoff.agent.started", fields: ["count": tally.backendTurnCount])
                case .commandSucceeded:
                    log.event("handoff.command.completed", fields: ["count": tally.completedCommands])
                case .commandFailed:
                    log.event("handoff.command.failed", fields: ["count": tally.failedCommands])
                case .agentCompleted:
                    log.event("handoff.agent.completed")
                }
                continue
            }
            guard method == "thread/realtime/transcript/done",
                  let params,
                  let role = params["role"] as? String,
                  let text = params["text"] as? String
            else { continue }

            log.event("media.transcript.completed", fields: [
                "characters": text.count,
                "role": role,
                "textHash": shortHash(text),
            ])
            if role == "user" {
                heardUser = true
            } else if role == "assistant" {
                heardAssistant = true
                assistantTranscript += " " + text
                if tally.sawAgentCompletion {
                    heardAssistantAfterAgentCompletion = true
                }
            }
        }
        guard heardUser else {
            throw RealtimeProbeError.missingMedia("no user transcript completed")
        }
        if let expectedAssistantSubstring,
           !assistantTranscript.localizedCaseInsensitiveContains(expectedAssistantSubstring)
        {
            throw RealtimeProbeError.missingMedia(
                "assistant response did not contain the expected resumed-context value"
            )
        }
        if expectHandoff {
            try tally.verifyDelegation(heardAssistantAfterAgentCompletion: heardAssistantAfterAgentCompletion)
        }

        try await Task.sleep(for: .seconds(1))
        let after = try await webRTC.mediaStatistics()
        logMediaStatistics(after, phase: "media.stats.after", log: log)
        guard after.outboundAudioBytes > before.outboundAudioBytes else {
            throw RealtimeProbeError.missingMedia("no outbound microphone RTP bytes")
        }
        guard after.inboundAudioBytes > before.inboundAudioBytes else {
            throw RealtimeProbeError.missingMedia("no inbound assistant-audio RTP bytes")
        }
        log.event("media.validated", fields: [
            "assistantTranscript": heardAssistant,
            "assistantTranscriptAfterAgentCompletion": heardAssistantAfterAgentCompletion,
            "backendTurnCount": tally.backendTurnCount,
            "completedCommands": tally.completedCommands,
            "handoffCount": tally.handoffCount,
            "userTranscript": heardUser,
        ])
    }

    private static func logMediaStatistics(
        _ statistics: RealtimeWebRTCSession.MediaStatistics,
        phase: String,
        log: ProbeLog
    ) {
        log.event(phase, fields: [
            "inboundAudioBytes": statistics.inboundAudioBytes,
            "inboundAudioPackets": statistics.inboundAudioPackets,
            "outboundAudioBytes": statistics.outboundAudioBytes,
            "outboundAudioPackets": statistics.outboundAudioPackets,
        ])
    }
}
