import Foundation
import Network
import Observation
import Testing
@testable import RemoteCoderCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StopContinuationTests {
    @Test(arguments: [false, true])
    func successorWaitsForMatchingCompletionAndFullStopResponse(responseFirst: Bool) async throws {
        let fixture = try await StopFixture.open()
        let message = try await fixture.submit("Continue", steering: true)
        await fixture.session.accepted(message.id, turnID: fixture.turn.turnID)
        fixture.stop()
        let stop = try await fixture.socket.request("turn/interrupt")
        fixture.dispatcher.turnCompleted(threadID: fixture.turn.threadID, turnID: "unrelated")
        if responseFirst {
            try await fixture.socket.reply(stop, result: .object([:]))
            await fixture.waitForRefresh()
        }
        #expect(await fixture.socket.count("turn/start") == 0)
        await fixture.complete()
        #expect(fixture.turns.isBusy(conversationID: fixture.conversationID, threadID: fixture.turn.threadID))
        if !responseFirst { try await fixture.socket.reply(stop, result: .object([:])) }
        let next = try await fixture.socket.request("turn/start")
        #expect(next.params?.objectValue?["clientUserMessageId"]?.stringValue == message.id.uuidString)
        #expect(next.params?.objectValue?["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "Continue")
        await fixture.waitForSuccessor()
        fixture.dispatcher.turnCompleted(threadID: fixture.turn.threadID, turnID: fixture.turn.turnID)
        await fixture.close()
        #expect(await fixture.socket.count("turn/start") == 1)
    }

    @Test(arguments: [false, true])
    func failedStopNeverDispatchesTheAcceptedSteer(completionFirst: Bool) async throws {
        let fixture = try await StopFixture.open()
        let message = try await fixture.submit("Continue", steering: true)
        await fixture.session.accepted(message.id, turnID: fixture.turn.turnID)
        fixture.stop()
        let stop = try await fixture.socket.request("turn/interrupt")
        if completionFirst {
            await fixture.complete()
            #expect(fixture.turns.isBusy(conversationID: fixture.conversationID, threadID: fixture.turn.threadID))
        }
        try await fixture.socket.refuse(stop)
        await fixture.waitForFailure()
        if !completionFirst { await fixture.complete() }
        await fixture.close()
        #expect(await fixture.socket.count("turn/start") == 0)
        #expect(await fixture.socket.count("thread/queue/start") == 0)
        #expect((await fixture.session.snapshot()).messages.contains { $0.id == message.id })
    }

    @Test func lateSteerReceiptsMergeOnceAfterStopAndKeepOnlyAcceptedUntakenInput() async throws {
        let fixture = try await StopFixture.open()
        let original = try await fixture.submit("Original", steering: false)
        let taken = try await fixture.submit("Taken", steering: true)
        let first = try await fixture.submit("First", steering: true, input: "prompt First")
        for message in [original, taken, first] { await fixture.session.accepted(message.id, turnID: fixture.turn.turnID) }
        let takenID = taken.id.uuidString
        await fixture.session.ingest(try GatewayEventFixture.item("item/completed",
            item: .userMessage(id: takenID, content: [.text(text: "Taken", textElements: [])], clientId: takenID),
            threadID: fixture.turn.threadID, turnID: fixture.turn.turnID, ordinal: 1, startedAtMs: 1000, completedAtMs: 1000), replay: false)
        let uncertain = try await fixture.submit("Uncertain", steering: true)
        await fixture.session.submissionFailed(uncertain.id, failure: .uncertain("No receipt"))
        let second = try await fixture.submit("Second", steering: true, input: "prompt Second")
        let third = try await fixture.submit("Third", steering: true, input: "prompt Third")
        let rejected = try await fixture.submit("Rejected", steering: true)
        for message in [second, third, rejected] { fixture.steer(message, input: "prompt \(message.text)") }
        let requests = try await fixture.socket.requests("turn/steer", count: 3)
        fixture.stop()
        let stop = try await fixture.socket.request("turn/interrupt")
        await fixture.complete()
        try await fixture.socket.reply(stop, result: .object([:]))
        await fixture.waitForRefresh()
        #expect(fixture.turns.isBusy(conversationID: fixture.conversationID, threadID: fixture.turn.threadID))
        for request in requests.reversed() {
            if request.params?.objectValue?["clientUserMessageId"]?.stringValue == rejected.id.uuidString {
                try await fixture.socket.turnEnded(request)
            } else {
                try await fixture.socket.reply(request, result: .object(["turnId": .string(fixture.turn.turnID)]))
            }
        }
        let next = try await fixture.socket.request("turn/start")
        #expect(next.params?.objectValue?["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "prompt First\nprompt Second\nprompt Third")
        let mergedID = try #require(next.params?.objectValue?["clientUserMessageId"]?.stringValue.flatMap(UUID.init(uuidString:)))
        await fixture.waitForSuccessor()
        let snapshot = await fixture.session.snapshot()
        #expect(snapshot.messages.first { $0.id == mergedID }?.text == "First\nSecond\nThird")
        #expect(Set(snapshot.messages.map(\.id)).isDisjoint(with: [first.id, second.id, third.id]))
        #expect(Set(snapshot.messages.map(\.id)).isSuperset(of: [original.id, taken.id, uncertain.id, rejected.id]))
        await fixture.close()
        #expect(await fixture.socket.count("turn/start") == 1)
        #expect(await fixture.socket.count("thread/queue/start") == 0)
    }

    @Test(arguments: [false, true])
    func codexContinuesTheServerFIFOIncludingOtherDeviceEntries(hasLocalReceipt: Bool) async throws {
        let fixture = try await StopFixture.open()
        let remote = CodexAppServerV2.QueuedSubmission(id: "remote-first", clientUserMessageId: "other-device-client")
        var entries = [remote]
        if hasLocalReceipt {
            let local = ChatMessage(role: .user, text: "Local later")
            _ = try await fixture.session.submitToQueue(local, input: local.text)
            let receipt = CodexAppServerV2.QueuedSubmission(id: "local-later", clientUserMessageId: local.id.uuidString)
            await fixture.session.queued(local.id, submission: receipt)
            entries.append(receipt)
        }
        await fixture.socket.setQueue(entries)
        fixture.stop()
        let stop = try await fixture.socket.request("turn/interrupt")
        await fixture.complete()
        try await fixture.socket.reply(stop, result: .object([:]))
        let next = try await fixture.socket.request("thread/queue/start")
        #expect(next.params?.objectValue?["queuedSubmissionId"]?.stringValue == "remote-first")
        #expect(next.params?.objectValue?["threadId"]?.stringValue == fixture.turn.threadID)
        await fixture.waitForSuccessor()
        await fixture.close()
        #expect(await fixture.socket.count("turn/start") == 0)
        #expect(await fixture.socket.count("thread/queue/start") == 1)
    }

    @Test func retirementCancelsStopOwnershipAndLateSteerReceiptsCannotDispatch() async throws {
        let fixture = try await StopFixture.open()
        let steer = try await fixture.submit("Continue", steering: true)
        fixture.steer(steer, input: steer.text)
        _ = try await fixture.socket.request("turn/steer")
        fixture.stop()
        _ = try await fixture.socket.request("turn/interrupt")
        await fixture.complete()
        await fixture.close()
        #expect(!fixture.turns.isBusy(conversationID: fixture.conversationID, threadID: fixture.turn.threadID))
        #expect(!fixture.turns.isSteering(threadID: fixture.turn.threadID))
        #expect(await fixture.socket.count("turn/start") == 0)
        #expect(await fixture.socket.count("thread/queue/start") == 0)
    }

    @Test func quiescingReleasesStopOwnershipAndResumeCannotDispatchItsSuccessor() async throws {
        let fixture = try await StopFixture.open()
        let steer = try await fixture.submit("Continue", steering: true)
        await fixture.session.accepted(steer.id, turnID: fixture.turn.turnID)
        fixture.stop()
        let stop = try await fixture.socket.request("turn/interrupt")
        await fixture.complete()
        #expect(fixture.turns.isBusy(conversationID: fixture.conversationID, threadID: fixture.turn.threadID))
        fixture.dispatcher.quiesce()
        #expect(!fixture.turns.isBusy(conversationID: fixture.conversationID, threadID: fixture.turn.threadID))
        try await fixture.socket.reply(stop, result: .object([:]))
        await fixture.dispatcher.drain()
        fixture.dispatcher.resume()
        #expect((await fixture.session.snapshot()).messages.contains { $0.id == steer.id })
        await fixture.close()
        #expect(await fixture.socket.count("turn/start") == 0)
        #expect(await fixture.socket.count("thread/queue/start") == 0)
    }

    @Test func quiescingDuringMergedInputPersistenceKeepsAnUnsentReceiptAcrossColdRecovery() async throws {
        let fixture = try await StopFixture.open()
        let directory = fixture.temporary.storage.directory(for: .device)
            .appending(path: "conversations-v1/\(fixture.hostID)")
        do {
            try await withCheckpointWriteGate(directory.appending(path: "\(fixture.conversationID).sqlite")) { gate in
                let pasted = MessageAttachment(id: UUID(), content: .text("Log text\nSecond line"))
                let file = MessageAttachment(id: UUID(), content: .file(.init(path: "/tmp/report.txt", bytes: 17, sha256: "fixture-hash")))
                let first = ChatMessage(role: .user, text: "First", attachments: [pasted],
                    wasSteered: true, canonicalTurnID: fixture.turn.turnID)
                let second = ChatMessage(role: .user, text: "Second", attachments: [file],
                    wasSteered: true, canonicalTurnID: fixture.turn.turnID)
                _ = try await fixture.session.submitDurably(first, input: "Dispatch First\nLog text\nSecond line")
                _ = try await fixture.session.submitDurably(second, input: "Dispatch Second\n/tmp/report.txt")
                await fixture.session.accepted(first.id, turnID: fixture.turn.turnID)
                await fixture.session.accepted(second.id, turnID: fixture.turn.turnID)
                try await fixture.session.flush()
                fixture.stop()
                let stop = try await fixture.socket.request("turn/interrupt")
                try await fixture.socket.reply(stop, result: .object([:]))
                await fixture.waitForRefresh()
                gate.arm()
                await fixture.complete()
                try await gate.waitForWrite()

                let duringWrite = await fixture.session.snapshot()
                #expect(duringWrite.messages.count == 1)
                let merged = try #require(duringWrite.messages.first)
                #expect(![first.id, second.id].contains(merged.id))
                #expect(!merged.wasSteered)
                #expect(merged.text == "First\nSecond")
                #expect(merged.attachments == [pasted, file])
                #expect(fixture.turns.isBusy(conversationID: fixture.conversationID, threadID: fixture.turn.threadID))
                fixture.dispatcher.quiesce()
                #expect(!fixture.turns.isBusy(conversationID: fixture.conversationID, threadID: fixture.turn.threadID))
                gate.release()
                await fixture.dispatcher.drain()
                fixture.dispatcher.resume()
                await fixture.dispatcher.drain()

                let live = await fixture.session.snapshot()
                #expect(live.messages.count == 1)
                #expect(live.messages.first?.delivery == .notSent)
                #expect(live.messages.first?.text == "First\nSecond")
                #expect(live.messages.first?.attachments == [pasted, file])
                let cold = ConversationCheckpointStore(hostID: fixture.hostID, storage: fixture.temporary.storage,
                    primaryBudgetBytes: 512 * 1_024 * 1_024)
                let checkpoint = try #require(try await cold.load(fixture.conversationID, threadID: fixture.turn.threadID))
                #expect(checkpoint.submissions.count == 1)
                let saved = try #require(checkpoint.submissions[merged.id])
                #expect(saved.status == .failed)
                #expect(saved.input == "Dispatch First\nLog text\nSecond line\nDispatch Second\n/tmp/report.txt")
                #expect(saved.message.attachments == [pasted, file])
                let restored = await ConversationSession.make(conversationID: fixture.conversationID,
                    threadID: fixture.turn.threadID, checkpoints: cold)
                try await restored.restore()
                let reopened = await restored.snapshot()
                #expect(reopened.messages.map(\.id) == [merged.id])
                #expect(reopened.messages.first?.delivery == .notSent)
                #expect(reopened.messages.first?.text == "First\nSecond")
                #expect(reopened.messages.first?.attachments == [pasted, file])
                #expect(await fixture.socket.count("turn/start") == 0)
                #expect(await fixture.socket.count("thread/queue/start") == 0)
                #expect(!fixture.turns.isBusy(conversationID: fixture.conversationID, threadID: fixture.turn.threadID))
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}

@MainActor
private final class StopFixture: TurnDispatchHost {
    let temporary = TemporaryHostStorage()
    let hostID = UUID()
    let conversationID = UUID()
    let turn = RunningTurn(threadID: "thread", turnID: "turn")
    let turns = TurnRegistry()
    let socket: StopSocket
    let gateway: GatewayClient
    let stops: TurnStops
    let conversations: ConversationSessions
    let drafts: ComposerDraftStore
    let settings = TurnDispatcher.Settings(model: .unlisted(id: "gpt-6.1-sol", reportedEffort: .medium, reportedFastMode: false),
        reasoning: .automatic, serviceTier: nil, fastModeState: .selection(false), workingDirectory: "/tmp", selectionRevision: 0)
    var isRetired = false
    var refreshed = false
    var refreshWaiter: CheckedContinuation<Void, Never>?
    var failureWaiter: CheckedContinuation<Void, Never>?
    var failed = false
    let index: ConversationIndex
    let metadata: ConversationMetadataService
    lazy var dispatcher = TurnDispatcher(host: self, gateway: gateway, turns: turns, stops: stops,
        conversations: conversations, sessionIndex: index, metadata: metadata, drafts: drafts)
    var session: ConversationSession
    var draft: ComposerDraft

    private init(socket: StopSocket, gateway: GatewayClient) async throws {
        self.socket = socket
        self.gateway = gateway
        stops = TurnStops(gateway: gateway)
        index = ConversationIndex(hostID: hostID, storage: temporary.storage)
        conversations = ConversationSessions(hostID: hostID, sessionIndex: index, contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        metadata = ConversationMetadataService(remote: gateway, store: ConversationMetadataStore(hostID: hostID, storage: temporary.storage))
        drafts = ComposerDraftStore(directory: temporary.storage.root.appending(path: "drafts"))
        draft = try #require(await drafts.draft(for: .thread("thread")))
        session = await conversations.session(conversationID: conversationID, threadID: "thread")
        try await session.restore()
        _ = turns.adopt(threadID: turn.threadID, turnID: turn.turnID)
    }

    static func open() async throws -> StopFixture {
        let socket = try StopSocket()
        let port = try await socket.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")), authToken: "fixture", hostLabel: "Stop fixture"), routes: nil)
        try await gateway.connectIfNeeded()
        return try await StopFixture(socket: socket, gateway: gateway)
    }

    func submit(_ text: String, steering: Bool, input: String? = nil) async throws -> ChatMessage {
        let message = ChatMessage(role: .user, text: text, wasSteered: steering, canonicalTurnID: steering ? turn.turnID : nil)
        _ = try await session.submitDurably(message, input: input ?? text)
        return message
    }

    func steer(_ message: ChatMessage, input: String) {
        dispatcher.steer(.init(draft: draft, conversationID: conversationID, userMessageID: message.id, input: input,
            interactionMode: .text, settings: settings), activeTurn: .init(threadID: turn.threadID, turnID: turn.turnID, jobID: "thread|turn"))
    }

    func stop() {
        dispatcher.stop(turn, followUp: .init(conversationID: conversationID, draft: draft, settings: settings), feedback: feedbackForCurrentConversation())
    }

    func complete() async {
        _ = turns.complete(threadID: turn.threadID, turnID: turn.turnID)
        dispatcher.turnCompleted(threadID: turn.threadID, turnID: turn.turnID)
    }

    func waitForRefresh() async {
        if !refreshed { await withCheckedContinuation { refreshWaiter = $0 } }
    }

    func waitForFailure() async {
        if !failed { await withCheckedContinuation { failureWaiter = $0 } }
    }

    func waitForSuccessor() async {
        while turns.turn(forThread: turn.threadID)?.turnID != "successor" {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = turns.turn(forThread: turn.threadID) } onChange: { continuation.resume() }
            }
        }
    }

    func close() async {
        isRetired = true
        let tasks = dispatcher.cancelAll()
        await socket.stop()
        await gateway.disconnect()
        for task in tasks { await task.value }
        temporary.cleanUp()
    }

    func feedbackForCurrentConversation() -> (HapticEvent) -> Void {
        { [self] event in
            if event == .error { failed = true; failureWaiter?.resume(); failureWaiter = nil }
        }
    }
    func isVisibleConversation(_ conversationID: UUID, sessionID: String?) -> Bool { false }
    func speakIfOwningAudio(_ text: String) {}
    func turnsChanged(_ change: TurnRegistryChange) {}
    func synchronizeConversationActivity() {}
    func retireGatewayJob(threadID: String, turnID: String?, jobID: String) {}
    func startActivityRefresh() { refreshed = true; refreshWaiter?.resume(); refreshWaiter = nil }
    func reconcileInputDelivery(threadID: String) async {}
    func threadStarted(_ thread: CodexAppServerV2.Thread, session: ConversationSession, settingsRevision: UInt64,
                       requestedServiceTier: CodexAppServerV2.ServiceTierOverride?) async {}
    func selectionIsCurrent(revision: UInt64, threadID: String) -> Bool { false }
}

private actor StopSocket {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "StopSocket")
    private var stopped = false
    private var connection: NWConnection?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var received: [CodexAppServerV2.JSONRPC.Request] = []
    private var waiters: [(String, Int, AsyncStream<[CodexAppServerV2.JSONRPC.Request]>.Continuation)] = []
    private var queued: [CodexAppServerV2.QueuedSubmission] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
            listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            listener.start(queue: queue)
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        if case .ready = state, let port = listener.port { ready?.resume(returning: port.rawValue); ready = nil }
        if case .failed(let error) = state { ready?.resume(throwing: error); ready = nil }
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        receive(connection)
        Task { try? await send(.notification(.init(method: "daemon/ready", params: .object([
            "notificationEpoch": .string("fixture"), "notificationSequence": .number(0)])))) }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            if error != nil || opcode == .close { connection.cancel(); return }
            if opcode == .ping || opcode == .pong { Task { await self?.receive(connection) }; return }
            guard let data else { connection.cancel(); return }
            Task { await self?.handle(data, connection: connection) }
        }
    }

    private func handle(_ data: Data, connection: NWConnection) async {
        do {
            let frame = try JSONDecoder().decode(CodexAppServerV2.JSONRPC.Message.self, from: data)
            if case .request(let request) = frame {
                received.append(request)
                let satisfied = waiters.filter { count($0.0) >= $0.1 }
                waiters.removeAll { count($0.0) >= $0.1 }
                for waiter in satisfied {
                    waiter.2.yield(received.filter { $0.method == waiter.0 })
                    waiter.2.finish()
                }
                switch request.method {
                case "turn/interrupt", "turn/steer": break
                case "daemon/activeTurns":
                    try await reply(request, result: .object([
                        "epoch": .string("fixture"), "revision": .number(1), "activeTurns": .array([]),
                        "coverage": .object(["codex": .bool(true), "claude": .bool(true)]),
                        "externalActivity": .object(["sessions": .array([]), "claudeAvailable": .bool(true), "codexAvailable": .bool(true)]),
                        "agentOwners": .object([:]),
                    ]))
                case "thread/resume":
                    try await reply(request, result: .object(["thread": try json(CodexAppServerV2.Thread.historyFixture())]))
                case "thread/queue/list":
                    try await reply(request, result: .object(["data": .array(queued.map { .object(["id": .string($0.id), "clientUserMessageId": .string($0.clientUserMessageId)]) })]))
                case "turn/start", "thread/queue/start":
                    try await reply(request, result: .object(["turn": .object(["id": .string("successor"), "status": .string("inProgress"), "items": .array([])])]))
                default: try await reply(request, result: .object([:]))
                }
            }
            receive(connection)
        } catch {
            if !stopped { Issue.record(error) }
            connection.cancel()
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func count(_ method: String) -> Int { received.filter { $0.method == method }.count }
    func setQueue(_ entries: [CodexAppServerV2.QueuedSubmission]) { queued = entries }
    func requests(_ method: String, count: Int) async throws -> [CodexAppServerV2.JSONRPC.Request] {
        if self.count(method) >= count { return received.filter { $0.method == method } }
        let pair = AsyncStream<[CodexAppServerV2.JSONRPC.Request]>.makeStream()
        waiters.append((method, count, pair.continuation))
        var iterator = pair.stream.makeAsyncIterator()
        guard let requests = await iterator.next() else { throw CancellationError() }
        return requests
    }
    func request(_ method: String) async throws -> CodexAppServerV2.JSONRPC.Request {
        try await requests(method, count: 1)[0]
    }
    func reply(_ request: CodexAppServerV2.JSONRPC.Request, result: JSONValue) async throws {
        try await send(.response(.init(id: request.id, result: result)))
    }
    func refuse(_ request: CodexAppServerV2.JSONRPC.Request) async throws {
        try await send(.error(.init(error: .init(code: -32603, data: nil, message: "Cleanup refused"), id: request.id)))
    }
    func turnEnded(_ request: CodexAppServerV2.JSONRPC.Request) async throws {
        try await send(.error(.init(error: .init(code: -32600, data: .object([
            "kind": .string("turnNotRunning"), "threadId": .string("thread"), "turnId": .string("turn"), "retryable": .bool(false),
        ]), message: "The turn ended"), id: request.id)))
    }
    private func send(_ frame: CodexAppServerV2.JSONRPC.Message) async throws {
        let connection = try #require(connection)
        let data = try JSONEncoder().encode(frame)
        let context = NWConnection.ContentContext(identifier: "jsonrpc", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func stop() {
        stopped = true
        connection?.cancel()
        listener.cancel()
        for waiter in waiters { waiter.2.finish() }
        waiters.removeAll()
    }
}
