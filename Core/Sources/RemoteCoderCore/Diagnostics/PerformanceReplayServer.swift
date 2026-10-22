#if RC_PERF_HARNESS || SWIFT_PACKAGE
import Foundation
import Network

actor PerformanceReplayServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RemoteCoder.PerformanceReplayServer", qos: .userInitiated)
    private var state: PerformanceReplayState
    private struct Peer {
        let connection: NWConnection
        var subscriptions: [String: String] = [:]
        var claudeThreads: Set<String> = []

        func receives(_ frame: JSONValue) -> Bool {
            guard let fields = frame.objectValue, let method = fields["method"]?.stringValue,
                  let thread = fields["params"]?.objectValue?["threadId"]?.stringValue else { return true }
            let claude = thread.hasPrefix("claude_")
            let global = ["thread/status/changed", "thread/goal/cleared", "conversation/questions/changed", "conversation/marks/changed"]
            if global.contains(method) { return true }
            if claude && ["turn/started", "turn/completed", "thread/started", "thread/closed", "thread/deleted",
                "thread/archived", "thread/unarchived", "thread/name/updated", "thread/settings/updated",
                "thread/history/invalidated", "thread/compacted", "directory/favorites/changed", "preferences/changed",
                "daemon/activeTurnsChanged", "daemon/ready", "account/updated", "account/rateLimits/updated", "host/state/changed"].contains(method) {
                return true
            }
            return claude ? claudeThreads.contains(thread) : subscriptions.values.contains(thread)
        }
    }
    private var peers: [UUID: Peer] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var ready: CheckedContinuation<UInt16, any Error>?
    private var stopped = false
    private(set) var failures: [String] = []

    init(scenario: PerformanceReplayScenario) throws {
        try scenario.validate()
        state = try PerformanceReplayState(scenario)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 16 * 1_048_576
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
        listener.newConnectionLimit = 8
    }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] state in Task { await self?.listenerChanged(state) } }
                listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
                listener.start(queue: queue)
            }
        } onCancel: { Task { await self.stop() } }
    }

    private func listenerChanged(_ status: NWListener.State) {
        switch status {
        case .ready:
            guard let port = listener.port else { return }
            ready?.resume(returning: port.rawValue)
            ready = nil
        case .failed(let error):
            ready?.resume(throwing: error)
            ready = nil
            if failures.count < 128 { failures.append(error.localizedDescription) }
        case .cancelled:
            ready?.resume(throwing: CancellationError())
            ready = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, peers.count < 4 else { connection.cancel(); return }
        let id = UUID()
        peers[id] = Peer(connection: connection)
        connection.start(queue: queue)
        tasks[id] = Task(name: "Performance replay socket") { [weak self] in
            await self?.serve(connection, id: id)
        }
    }

    private func serve(_ connection: NWConnection, id: UUID) async {
        defer { connection.cancel(); peers.removeValue(forKey: id); tasks.removeValue(forKey: id) }
        do {
            try await send(.object(["method": .string("daemon/ready"), "params": .object([
                "notificationEpoch": .string("performance-replay"), "notificationSequence": .number(0)
            ])]), on: connection)
            while !stopped, !Task.isCancelled {
                guard let data = try await receive(connection) else { continue }
                let request = try JSONDecoder().decode(JSONValue.self, from: data)
                if let response = try state.response(to: request) {
                    try await send(try recordSubscriptions(request, response: response, peerID: id), on: connection)
                }
            }
        } catch is CancellationError {
        } catch {
            if !stopped, !Task.isCancelled, failures.count < 128 { failures.append(String(describing: error)) }
        }
    }

    private func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, context, _, error in
                if let error { continuation.resume(throwing: error); return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close { continuation.resume(throwing: CancellationError()); return }
                if metadata?.opcode == .ping || metadata?.opcode == .pong {
                    continuation.resume(returning: nil)
                    return
                }
                guard metadata?.opcode == .text, let data else {
                    continuation.resume(throwing: PerformanceReplayScenario.Failure.invalidScenario("socket opcode \(String(describing: metadata?.opcode)), bytes \(data?.count ?? 0)"))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func send(_ value: JSONValue, on connection: NWConnection) async throws {
        let data = try JSONEncoder().encode(value)
        let context = NWConnection.ContentContext(identifier: "performance-replay",
            metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: context, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func recordSubscriptions(_ request: JSONValue, response: JSONValue, peerID: UUID) throws -> JSONValue {
        guard var peer = peers[peerID], var fields = response.objectValue,
              var result = fields["result"]?.objectValue else { return response }
        let params = request.objectValue?["params"]?.objectValue ?? [:]
        switch request.objectValue?["method"]?.stringValue {
        case "thread/subscribe":
            guard let thread = params["threadId"]?.stringValue, peer.subscriptions.count < 64 else {
                throw PerformanceReplayScenario.Failure.invalidScenario("invalid or excessive subscriptions")
            }
            let handle = UUID().uuidString
            peer.subscriptions[handle] = thread
            result["subscriptionId"] = .string(handle)
        case "thread/subscription/close":
            if let handle = params["subscriptionId"]?.stringValue { peer.subscriptions.removeValue(forKey: handle) }
        case "conversation/subscriptions/set":
            guard let values = params["threadIds"]?.arrayValue, values.count <= 64 else {
                throw PerformanceReplayScenario.Failure.invalidScenario("invalid content subscriptions")
            }
            peer.claudeThreads = Set(values.compactMap(\.stringValue))
        default: return response
        }
        peers[peerID] = peer
        fields["result"] = .object(result)
        return .object(fields)
    }

    @discardableResult func deliver(_ frame: JSONValue) async throws -> Int {
        guard !stopped, !peers.isEmpty else { throw PerformanceReplayScenario.Failure.invalidScenario("no replay client connected") }
        state.apply(frame)
        let notification = state.notification(frame)
        var recipients = 0
        for id in Array(peers.keys) {
            if let peer = peers[id], peer.receives(notification) {
                try await send(notification, on: peer.connection)
                recipients += 1
            }
        }
        return recipients
    }

    func diagnostics() -> (requests: [String: Int], unsupported: [String: Int], unsupportedRequests: [JSONValue], failures: [String]) {
        (state.requests, state.unsupported, state.unsupportedRequests, failures)
    }

    func stop() async {
        stopped = true
        listener.cancel()
        ready?.resume(throwing: CancellationError())
        ready = nil
        let running = Array(tasks.values)
        for task in running { task.cancel() }
        for peer in peers.values { peer.connection.cancel() }
        for task in running { await task.value }
        peers.removeAll()
        tasks.removeAll()
    }
}
#endif
