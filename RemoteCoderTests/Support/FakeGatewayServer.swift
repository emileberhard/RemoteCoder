import CryptoKit
import Foundation
import Network
import Testing
@testable import RemoteCoder

actor FakeGatewayServer {
    private struct Request {
        let method: String
        let params: JSONValue
    }

    struct TurnStart: Equatable {
        let threadID: String
        let text: String
    }

    private struct Delivery {
        let method: String
        let input: TurnStart
    }

    private struct HTTPRequest {
        let method: String
        let url: URLComponents?
        let headers: [String: String]
        let body: Data
    }

    private final class Peer {
        let connection: NWConnection
        var buffer = Data()
        var upgraded = false
        var message = Data()

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let listener: NWListener
    private var thread: JSONValue
    private var metadata: JSONValue = .array([])
    private var listedThreads: [JSONValue]?
    private var holdsThreadList = false
    private var heldThreadList: CheckedContinuation<Void, Never>?
    private var heldVisualResource: NWConnection?
    private var visualResourceArrival: CheckedContinuation<Void, Never>?
    private var threadListArrival: CheckedContinuation<Void, Never>?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var ready: CheckedContinuation<Int, Error>?
    private var deliveries: [Delivery] = []
    private var recordedRequests: [Request] = []
    private var models: JSONValue?
    private(set) var connectionCount = 0
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var initializedNotification: String?
    private var subscribes: [(threadID: String, id: JSONValue, connection: NWConnection)] = []
    private var subscribeWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    private var subscriptionsReleased = 0
    private var closedSubscription: String?
    private var closeWaiter: CheckedContinuation<String, Never>?
    private var activeTurnID: String?
    private var holdsTurnStarts = false
    private var heldTurnStart: CheckedContinuation<Void, Never>?
    private var turnStartArrival: CheckedContinuation<Void, Never>?
    private var history: [CodexAppServerV2.ThreadItemsListResponse.Entry]?
    private var holdsThreadRead = false
    private var holdsThreadStart = false
    private var heldThreadStart: CheckedContinuation<Void, Never>?
    private var threadStartArrival: CheckedContinuation<Void, Never>?
    private var heldThreadRead: CheckedContinuation<Void, Never>?
    private var threadReadArrival: CheckedContinuation<Void, Never>?
    private(set) var tailReads = 0
    private var failsTailReads = false
    private var holdsCursorPages = false
    private var heldPage: CheckedContinuation<Void, Never>?
    private var pageArrival: CheckedContinuation<Void, Never>?
    private var holdsTailPages = false
    private var heldTailPage: CheckedContinuation<Void, Never>?
    private var tailPageArrival: CheckedContinuation<Void, Never>?
    private var claudeAccounts: ClaudeRouterAccountList?
    private var claudeSelection: ClaudeRouterAccountList?
    private var claudeSelectionFailure = false
    private var failsClaudeRead = false
    private var dropsClaudeSelectionResponse = false
    private var holdsClaudeRead = false
    private var heldClaudeRead: CheckedContinuation<Void, Never>?
    private var claudeReadArrival: CheckedContinuation<Void, Never>?
    private(set) var claudeHTTPRequests: [(method: String, path: String, body: Data)] = []
    private var directory: AccountDirectoryResponse?
    private var holdsAgents = false
    private var heldAgents: CheckedContinuation<Void, Never>?

    func holdAgents() { holdsAgents = true }

    func releaseAgents() {
        holdsAgents = false
        heldAgents?.resume()
        heldAgents = nil
    }

    var turnStarts: [TurnStart] { deliveries.filter { $0.method == "turn/start" }.map(\.input) }
    var steers: [TurnStart] { deliveries.filter { $0.method == "turn/steer" }.map(\.input) }
    func requests(_ method: String) -> [JSONValue] {
        recordedRequests.filter { $0.method == method }.map(\.params)
    }
    func serveModels(_ models: [CodexAppServerV2.Model]) throws {
        self.models = try JSONDecoder().decode(JSONValue.self,
            from: JSONEncoder().encode(CodexAppServerV2.ModelListResponse(data: models, nextCursor: nil)))
    }

    func setListedThreads(_ headers: [ConversationHeader]) throws {
        listedThreads = try headers.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(CodexAppServerV2.ThreadReadResponse($0).thread)) }
    }
    func waitForRequest(_ method: String) async {
        if recordedRequests.contains(where: { $0.method == method }) { return }
        await withCheckedContinuation { requestWaiters[method, default: []].append($0) }
    }
    init(threadID: String = "thread", model: String = "model") throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        thread = .object([
            "id": .string(threadID), "preview": .string("Test"), "modelProvider": .string("anthropic"),
            "model": .string(model), "createdAt": .number(0), "updatedAt": .number(1), "cwd": .string("/repo"),
            "cliVersion": .string("test"), "source": .string("appServer"),
            "status": .object(["type": .string("notLoaded")]), "ephemeral": .bool(false), "turns": .array([])
        ])
    }

    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { await self?.listenerChanged(state) } }
            listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            listener.start(queue: .global(qos: .utility))
        }
    }

    func startURL() async throws -> URL {
        let port = try await start()
        return try #require(URL(string: "ws://127.0.0.1:\(port)"))
    }

    func notifyAfterInitialize(_ method: String) { initializedNotification = method }

    func waitForHeldVisualResource() async {
        if heldVisualResource != nil { return }
        await withCheckedContinuation { visualResourceArrival = $0 }
    }

    func releaseHeldVisualResource() async {
        guard let connection = heldVisualResource else { return }
        heldVisualResource = nil
        let body = Data("globalThis.resourceFinished = true;".utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        await withCheckedContinuation { continuation in
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
                continuation.resume()
            })
        }
    }

    func waitForSubscribe() async {
        await waitForSubscribes(1)
    }

    func waitForSubscribes(_ count: Int) async {
        if subscribes.count >= count { return }
        await withCheckedContinuation { subscribeWaiter = (count, $0) }
    }

    func waitForClose() async -> String {
        if let closedSubscription { return closedSubscription }
        return await withCheckedContinuation { closeWaiter = $0 }
    }

    func releaseSubscribe(malformed: Bool) async throws {
        try #require(!subscribes.isEmpty)
        try await releaseSubscribe(at: 0, malformed: malformed)
    }

    func releaseSubscribe(threadID: String) async throws {
        let index = try #require(subscribes.firstIndex { $0.threadID == threadID })
        try await releaseSubscribe(at: index, malformed: false)
    }

    private func releaseSubscribe(at index: Int, malformed: Bool) async throws {
        let request = subscribes.remove(at: index)
        subscriptionsReleased += 1
        var result: [String: JSONValue] = ["status": .string("subscribed"),
                                           "subscriptionId": .string("observer-\(subscriptionsReleased)")]
        if !malformed {
            result["thread"] = .object([
                "id": .string("thread"), "preview": .string(""), "modelProvider": .string("openai"),
                "createdAt": .number(1), "updatedAt": .number(1), "cwd": .string("/tmp"),
                "cliVersion": .string("test"), "source": .string("cli"), "turns": .array([])
            ])
            result["checkpoint"] = .object(["liveItems": .array([]), "historyUnavailable": .bool(false)])
        }
        try await send(.object(["id": request.id, "result": .object(result)]), on: request.connection)
    }

    func notify(_ method: String, _ params: [String: JSONValue]) async throws {
        let connection = try #require(peers.values.first(where: { $0.upgraded })?.connection)
        try await send(.object(["method": .string(method), "params": .object(params)]), on: connection)
    }

    func failClaudeRead(_ fails: Bool) { failsClaudeRead = fails }
    func dropClaudeSelectionResponse() { dropsClaudeSelectionResponse = true }
    func holdClaudeRead() { holdsClaudeRead = true }
    func waitForClaudeRead() async {
        if heldClaudeRead != nil { return }
        await withCheckedContinuation { claudeReadArrival = $0 }
    }
    func releaseClaudeRead() {
        holdsClaudeRead = false
        heldClaudeRead?.resume()
        heldClaudeRead = nil
    }

    func setClaudeAccounts(_ accounts: ClaudeRouterAccountList, selection: ClaudeRouterAccountList?, failsSelection: Bool) {
        claudeAccounts = accounts
        claudeSelection = selection
        claudeSelectionFailure = failsSelection
    }

    func stop() {
        releaseHeldTailPage()
        releaseHeldPage()
        peers.values.forEach { $0.connection.cancel() }
        peers = [:]
        listener.cancel()
    }

    func serveHistory(_ entries: [CodexAppServerV2.ThreadItemsListResponse.Entry]) { history = entries }
    func holdThreadRead() { holdsThreadRead = true }
    func holdThreadList() { holdsThreadList = true }
    func waitForHeldThreadList() async {
        if heldThreadList == nil { await withCheckedContinuation { threadListArrival = $0 } }
    }
    func releaseHeldThreadList() {
        holdsThreadList = false
        heldThreadList?.resume()
        heldThreadList = nil
    }
    func waitForHeldThreadRead() async {
        if heldThreadRead == nil { await withCheckedContinuation { threadReadArrival = $0 } }
    }
    func releaseHeldThreadRead() {
        holdsThreadRead = false
        heldThreadRead?.resume()
        heldThreadRead = nil
    }
    func serveMetadata(_ entries: [ConversationMetadata]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        metadata = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(entries))
    }
    func serveThreadSettings(model: String, effort: String?) {
        guard var fields = thread.objectValue else { preconditionFailure("Fixture thread is not an object") }
        fields["model"] = .string(model)
        fields["reasoningEffort"] = effort.map(JSONValue.string) ?? .null
        thread = .object(fields)
    }
    func serveThreadTier(_ tier: String?) {
        guard var fields = thread.objectValue else { preconditionFailure("Fixture thread is not an object") }
        fields["extra"] = .object(["serviceTier": tier.map(JSONValue.string) ?? .null])
        thread = .object(fields)
    }
    func holdThreadStart() { holdsThreadStart = true }
    func waitForHeldThreadStart() async {
        if heldThreadStart == nil { await withCheckedContinuation { threadStartArrival = $0 } }
    }
    func releaseHeldThreadStart() {
        holdsThreadStart = false
        heldThreadStart?.resume()
        heldThreadStart = nil
    }
    func reportActiveTurn(_ turnID: String) { activeTurnID = turnID }
    func holdTurnStarts() { holdsTurnStarts = true }
    func waitForHeldTurnStart() async {
        if heldTurnStart == nil { await withCheckedContinuation { turnStartArrival = $0 } }
    }
    func releaseTurnStart() {
        holdsTurnStarts = false
        heldTurnStart?.resume()
        heldTurnStart = nil
    }
    func failTailReads(_ fails: Bool) { failsTailReads = fails }
    func holdCursorPages() { holdsCursorPages = true }
    func waitForHeldPage() async {
        if heldPage == nil { await withCheckedContinuation { pageArrival = $0 } }
    }
    func releaseHeldPage() {
        holdsCursorPages = false
        heldPage?.resume()
        heldPage = nil
    }

    func holdTailPages() { holdsTailPages = true }
    func waitForHeldTailPage() async {
        if heldTailPage == nil { await withCheckedContinuation { tailPageArrival = $0 } }
    }
    func releaseHeldTailPage() {
        holdsTailPages = false
        heldTailPage?.resume()
        heldTailPage = nil
    }

    func serveAccounts(_ directory: AccountDirectoryResponse) {
        self.directory = directory
    }

    private func historyPage(_ method: String, params: [String: JSONValue],
                             entries: [CodexAppServerV2.ThreadItemsListResponse.Entry]) async throws -> JSONValue {
        guard method == "thread/items/list" else {
            return .object(["data": .array([]), "nextCursor": .null, "backwardsCursor": .null])
        }
        let cursor = params["cursor"]?.stringValue.flatMap(Int.init)
        if cursor != nil, holdsCursorPages {
            await withCheckedContinuation { heldPage = $0; pageArrival?.resume(); pageArrival = nil }
        }
        if cursor == nil, holdsTailPages {
            await withCheckedContinuation { heldTailPage = $0; tailPageArrival?.resume(); tailPageArrival = nil }
        }
        let step = params["sortDirection"]?.stringValue == "asc" ? 1 : -1
        let limit: Int
        if case .number(let requested) = params["limit"] { limit = Int(requested) } else { limit = 50 }
        let start = cursor ?? (step == 1 ? 0 : entries.count - 1)
        let indices = (0..<limit).map { start + $0 * step }.filter(entries.indices.contains)
        let next = indices.last.map { $0 + step }.flatMap { entries.indices.contains($0) ? String($0) : nil }
        let data = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(indices.map { entries[$0] }))
        return .object(["data": data, "nextCursor": next.map(JSONValue.string) ?? .null,
                        "backwardsCursor": indices.first.map { .string(String($0)) } ?? .null])
    }

    private func activeTurns() -> [JSONValue] {
        guard let activeTurnID, let threadID = thread.objectValue?["id"] else { return [] }
        return [.object(["threadId": threadID, "turnId": .string(activeTurnID), "startedAtUnixSeconds": .number(1),
                         "promptPreview": .string("Running"), "cwd": .string("/repo")])]
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port { ready?.resume(returning: Int(port.rawValue)); ready = nil }
        case .failed(let error): ready?.resume(throwing: error); ready = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard peers.count < 16 else { connection.cancel(); return }
        connectionCount += 1
        peers[ObjectIdentifier(connection)] = Peer(connection)
        connection.start(queue: .global(qos: .utility))
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            Task { await self?.received(data, closed: isComplete || error != nil, connection: connection) }
        }
    }

    private func received(_ data: Data?, closed: Bool, connection: NWConnection) {
        guard let peer = peers[ObjectIdentifier(connection)] else { return }
        if let data { peer.buffer.append(data) }
        guard peer.buffer.count <= 8 * 1_024 * 1_024 else {
            peers[ObjectIdentifier(connection)] = nil
            connection.cancel()
            return
        }
        if !peer.upgraded, let request = takeRequest(from: peer) {
            guard request.headers["upgrade"]?.lowercased() == "websocket",
                  let key = request.headers["sec-websocket-key"] else {
                Task { await self.serve(request, on: connection) }
                return
            }
            peer.upgraded = true
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            connection.send(content: Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept.base64EncodedString())\r\n\r\n").utf8),
                            completion: .idempotent)
            Task { try? await self.send(.object(["method": .string("daemon/ready"), "params": .object([
                "notificationEpoch": .string("fixture"), "notificationSequence": .number(0)])]), on: connection) }
        }
        while peer.upgraded, let frame = takeFrame(from: peer) {
            switch frame.opcode {
            case 0x0, 0x1, 0x2:
                peer.message.append(frame.payload)
                guard peer.message.count <= 8 * 1_024 * 1_024 else {
                    peers[ObjectIdentifier(connection)] = nil
                    connection.cancel()
                    return
                }
                guard frame.final else { continue }
                let message = peer.message
                peer.message = Data()
                Task { await self.respond(to: message, on: connection) }
            case 0x8:
                connection.send(content: Self.frame(0x8, frame.payload), completion: .contentProcessed { _ in connection.cancel() })
                peers[ObjectIdentifier(connection)] = nil
                return
            case 0x9:
                connection.send(content: Self.frame(0xA, frame.payload), completion: .idempotent)
            default: break
            }
        }
        guard !closed else {
            peers[ObjectIdentifier(connection)] = nil
            connection.cancel()
            return
        }
        receive(connection)
    }

    private func takeRequest(from peer: Peer) -> HTTPRequest? {
        guard let end = peer.buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: peer.buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        guard peer.buffer.count - end.upperBound >= length else { return nil }
        let body = Data(peer.buffer[end.upperBound..<(end.upperBound + length)])
        peer.buffer = Data(peer.buffer[(end.upperBound + length)...])
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return HTTPRequest(method: "", url: nil, headers: headers, body: body) }
        return HTTPRequest(method: String(requestLine[0]), url: URLComponents(string: String(requestLine[1])), headers: headers, body: body)
    }

    private func takeFrame(from peer: Peer) -> (opcode: UInt8, final: Bool, payload: Data)? {
        let buffer = peer.buffer
        guard buffer.count >= 2 else { return nil }
        var offset = 2
        var length = Int(buffer[1] & 0x7F)
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = (2..<10).reduce(0) { $0 << 8 | Int(buffer[$1]) }
            offset = 10
        }
        let masked = buffer[1] & 0x80 != 0
        guard buffer.count >= offset + (masked ? 4 : 0) + length else { return nil }
        let mask = masked ? Array(buffer[offset..<offset + 4]) : []
        offset += mask.count
        var payload = Data(buffer[offset..<offset + length])
        if !mask.isEmpty { for index in payload.indices { payload[index] ^= mask[index % 4] } }
        peer.buffer = Data(buffer[(offset + length)...])
        return (buffer[0] & 0x0F, buffer[0] & 0x80 != 0, payload)
    }

    private static func frame(_ opcode: UInt8, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        switch payload.count {
        case ..<126: frame.append(UInt8(payload.count))
        case ..<65_536: frame.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default: frame.append(contentsOf: [127] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) })
        }
        return frame + payload
    }

    private func serve(_ request: HTTPRequest, on connection: NWConnection) async {
        var body: Data?
        var status = "200 OK"
        if let path = request.url?.path, path.hasPrefix("/claude/") {
            claudeHTTPRequests.append((request.method, path, request.body))
        }
        switch (request.method, request.url?.path) {
        case ("GET", "/held-visual.js"):
            heldVisualResource = connection
            visualResourceArrival?.resume()
            visualResourceArrival = nil
            return
        case ("GET", "/claude/accounts"), ("POST", "/claude/accounts/refresh"):
            if request.method == "GET", holdsClaudeRead {
                await withCheckedContinuation { heldClaudeRead = $0; claudeReadArrival?.resume(); claudeReadArrival = nil }
            }
            if failsClaudeRead {
                status = "503 Service Unavailable"
                body = Data("{\"error\":{\"code\":\"router_unavailable\",\"message\":\"Router unavailable\"}}".utf8)
            } else { body = try? claudeAccounts.map { try JSONEncoder().encode($0) } }
        case ("PUT", "/claude/accounts/preference"):
            if dropsClaudeSelectionResponse {
                claudeAccounts = claudeSelection
                peers[ObjectIdentifier(connection)] = nil
                connection.cancel()
                return
            }
            if claudeSelectionFailure {
                status = "503 Service Unavailable"
                body = Data("{\"error\":{\"code\":\"preference_unavailable\",\"message\":\"Preference could not be saved\"}}".utf8)
            } else {
                body = try? claudeSelection.map { try JSONEncoder().encode($0) }
            }
        case ("GET", "/accounts"):
            body = try? directory.map { try JSONEncoder().encode($0) }
        default: break
        }
        peers[ObjectIdentifier(connection)] = nil
        guard let body else { connection.cancel(); return }
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respond(to data: Data, on connection: NWConnection) async {
        guard let fields = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue,
              let method = fields["method"]?.stringValue else { return }
        if method == "initialized", let initializedNotification {
            do { try await send(.object(["method": .string(initializedNotification), "params": .object([:])]), on: connection) }
            catch { Self.recordUnlessPeerLeft(error) }
            return
        }
        guard let id = fields["id"] else { return }
        let params = fields["params"]?.objectValue ?? [:]
        recordedRequests.append(Request(method: method, params: .object(params)))
        if recordedRequests.count > 512 { recordedRequests.removeFirst(recordedRequests.count - 512) }
        requestWaiters.removeValue(forKey: method)?.forEach { $0.resume() }
        if method == "conversation/agents/list", holdsAgents {
            await withCheckedContinuation { heldAgents = $0 }
        }
        if method == "thread/read", holdsThreadRead {
            await withCheckedContinuation { heldThreadRead = $0; threadReadArrival?.resume(); threadReadArrival = nil }
        }
        if method == "thread/start", holdsThreadStart {
            await withCheckedContinuation { heldThreadStart = $0; threadStartArrival?.resume(); threadStartArrival = nil }
        }
        if method == "thread/subscribe" {
            subscribes.append((params["threadId"]?.stringValue ?? "", id, connection))
            if let waiter = subscribeWaiter, subscribes.count >= waiter.count {
                subscribeWaiter = nil
                waiter.continuation.resume()
            }
            return
        }
        if method == "thread/subscription/close" {
            do {
                try await send(.object(["id": id, "result": .object([:])]), on: connection)
                closedSubscription = params["subscriptionId"]?.stringValue
                if let closedSubscription {
                    closeWaiter?.resume(returning: closedSubscription)
                    closeWaiter = nil
                }
            } catch { Self.recordUnlessPeerLeft(error) }
            return
        }
        var result: JSONValue? = switch method {
        case "initialize": .object([:])
        case "conversation/subscriptions/set": .object([:])
        case "conversation/metadata/read": .object(["entries": metadata])
        case "conversation/agents/list": .object(["agents": .array([]), "revision": .string("1"), "warnings": .array([])])
        case "model/list": models
        case "thread/list": listedThreads.map { .object(["data": .array($0), "nextCursor": .null]) }
        case "claude/thread/list": listedThreads.map { _ in .object(["data": .array([]), "nextCursor": .null]) }
        case "daemon/activeTurns":
            .object(["epoch": .string("fake-epoch"), "revision": .number(1), "activeTurns": .array(activeTurns()),
                     "coverage": .object(["codex": .bool(true), "claude": .bool(true)]),
                     "agentOwners": .object([:]),
                     "externalActivity": .object(["sessions": .array([]), "claudeAvailable": .bool(true),
                                                  "codexAvailable": .bool(true)])])
        case "thread/start", "thread/resume", "thread/read": .object(["thread": thread])
        case "turn/start":
            .object(["turn": .object(["id": .string("turn-\(turnStarts.count + 1)"), "status": .string("inProgress")])])
        case "turn/steer": .object(["turnId": params["expectedTurnId"] ?? .null])
        case "conversation/settings/update":
            .object(["status": .string(activeTurnID == nil ? "applied" : "nextTurn"),
                     "currentTurnId": activeTurnID.map(JSONValue.string) ?? .null, "warning": .null])
        default: nil
        }
        if method == "thread/list", holdsThreadList {
            await withCheckedContinuation { heldThreadList = $0; threadListArrival?.resume(); threadListArrival = nil }
        }
        var failure: JSONValue?
        if let history, method == "thread/items/list" || method == "thread/turns/list" {
            if method == "thread/items/list", params["cursor"] == nil { tailReads += 1 }
            if failsTailReads, params["cursor"] == nil {
                failure = .object(["code": .number(-32000), "message": .string("History unavailable")])
            } else {
                do { result = try await historyPage(method, params: params, entries: history) } catch { Issue.record(error) }
            }
        }
        let input = TurnStart(threadID: params["threadId"]?.stringValue ?? "",
            text: params["input"]?.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue }.joined() ?? "")
        if method == "turn/steer" || method == "turn/start" {
            deliveries.append(Delivery(method: method, input: input))
            if deliveries.count > 512 { deliveries.removeFirst(deliveries.count - 512) }
        }
        if method == "turn/start", holdsTurnStarts {
            await withCheckedContinuation { heldTurnStart = $0; turnStartArrival?.resume(); turnStartArrival = nil }
        }
        let reply: JSONValue = failure.map { .object(["id": id, "error": $0]) } ?? result.map { .object(["id": id, "result": $0]) }
            ?? .object(["id": id, "error": .object(["code": .number(-32601), "message": .string("Method not found")])])
        do { try await send(reply, on: connection) } catch { Self.recordUnlessPeerLeft(error) }
    }

    private static func recordUnlessPeerLeft(_ error: any Error) {
        if case .posix(let code) = error as? NWError, [.ECANCELED, .ECONNRESET, .EPIPE, .ENOTCONN].contains(code) { return }
        Issue.record(error)
    }

    private func send(_ message: JSONValue, on connection: NWConnection) async throws {
        let data = Self.frame(0x1, try JSONEncoder().encode(message))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
