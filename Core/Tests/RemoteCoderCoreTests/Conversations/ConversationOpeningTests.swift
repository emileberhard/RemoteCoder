import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ConversationOpeningTests: ConversationHistoryFixtures {
    @Test(arguments: OpeningTailOutcome.allCases)
    func livePumpCompletionDuringOpeningPreservesOneCompletedTurn(_ outcome: OpeningTailOutcome) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let thread = "opening-completion"
        let index = ConversationIndex(hostID: hostID, storage: temporary.storage)
        let sessions = ConversationSessions(hostID: hostID, sessionIndex: index,
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let conversationID = UUID()
        await index.record(sessionID: thread, conversationID: conversationID)
        let socket = try DeviceToolSocketFixture(declarationReply: .accepted)
        let port = try await socket.start()
        let client = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let sink = OpeningLifecycleSink(address: .init(hostID: hostID, threadID: thread), index: index, sessions: sessions)
        let pump = GatewayEventPump(gateway: client, conversations: sessions, sink: sink)
        let pause = OpeningPause()
        let gateway = CompletionOpeningGateway(outcome: outcome)
        let history = GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: temporary.storage.root.appending(path: "pages")))
        let opening = Task {
            await pause.wait()
            let owner = await sessions.session(conversationID: conversationID, threadID: thread)
            try await owner.restore()
            let read = await owner.beginHistoryRead()
            do {
                let tail = try await history.openTail(header: .historyFixture(id: thread), base: read.base, bypassCache: true)
                #expect(outcome != .failure)
                _ = await owner.merge(tail, read: read)
            } catch {
                #expect(outcome == .failure)
                #expect((error as? URLError)?.code == .cannotConnectToHost)
            }
            return owner
        }
        defer {
            await pause.release()
            await gateway.releaseTail()
            _ = await opening.result
            let stopped = pump.stop()
            await client.retire()
            await socket.stop()
            for task in stopped { await task.value }
        }
        await pause.waitForOpening()
        #expect(await sessions.existingSession(threadID: thread) == nil)
        pump.startIfNeeded()
        try await eventually { await sink.connected }
        try await socket.send(.notification(.init(method: "turn/completed", params: .object([
            "threadId": .string(thread), "turn": .object([
                "id": .string("turn"), "status": .string("completed"), "completedAt": .number(20)
            ])
        ]))))
        try await eventually { await sink.deliveries == 1 }
        #expect(await sessions.existingSession(threadID: thread) != nil)
        await pause.release()
        await gateway.waitForTail()
        await gateway.releaseTail()
        let owner = try await opening.value
        let snapshot = await owner.snapshot()
        #expect(snapshot.conversationID == conversationID)
        #expect(snapshot.lastTurnCompletedAt == 20)
        if outcome != .failure {
            #expect(snapshot.messages.map(\.text) == ["A completed reply"])
            #expect(snapshot.messages.map(\.canonicalTurnID) == ["turn"])
        }
        try await owner.flush()
        let checkpoint = try #require(try await ConversationCheckpointStore(hostID: hostID, storage: temporary.storage, primaryBudgetBytes: 512 * 1_024 * 1_024).load(conversationID))
        #expect(checkpoint.order == ["turn"])
        #expect(checkpoint.turns.count == 1)
        #expect(checkpoint.turns["turn"]?.terminalStatus == .completed)
        #expect(checkpoint.turns["turn"]?.isActive == false)
        #expect(await sessions.existingSession(threadID: thread) === owner)
        await sessions.invalidate(threadID: thread)
    }

    enum Coverage: CaseIterable, Sendable {
        case retained, liveCheckpoint, missingPrefix, transportGap
    }

    @Test(arguments: Coverage.allCases)
    func reopeningKeepsAnExactStreamingPrefixAndRereadsAfterOwnerEviction(_ coverage: Coverage) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let thread = "claude_opening"
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let gateway = OpeningHistoryGateway()
        let history = GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: temporary.storage.root.appending(path: "pages")))
        let host = OpeningHost()
        let warmer = ConversationWarmer(host: host, conversations: sessions, history: history)
        let header = ConversationHeader.historyFixture(id: thread)
        var retained: ConversationSession? = await sessions.session(threadID: thread)
        await sessions.ingest(try event("item/started", item: .agentMessage(id: "answer", text: ""), ordinal: 1,
            threadID: thread), replay: false)
        await sessions.ingest(try GatewayEventFixture.delta("A", threadID: thread, turnID: "turn", itemID: "answer"), replay: false)
        _ = try await history.openTail(header: header, base: nil)
        warmer.readSucceeded(threadID: thread, observation: warmer.observation(threadID: thread, revision: header.updatedAt))
        #expect(!warmer.needsRead(threadID: thread, revision: header.updatedAt))
        let keepsOwner = coverage == .retained || coverage == .transportGap
        if !keepsOwner {
            retained = nil
            for index in 0..<17 { _ = await sessions.session(threadID: "filler-\(index)") }
            #expect(await sessions.existingSession(threadID: thread) == nil)
        }
        if coverage == .transportGap {
            await sessions.revokeStreamingPrefixes()
        } else {
            await sessions.ingest(try GatewayEventFixture.delta("B", threadID: thread, turnID: "turn", itemID: "answer"), replay: false)
        }
        let existing = await warmer.prepareOpening(threadID: thread)
        #expect((existing != nil) == keepsOwner)
        let owner = await sessions.session(threadID: thread)
        try await owner.restore()
        if coverage != .retained {
            await sessions.ingest(try event("item/started", item: .agentMessage(id: "answer", text: ""), ordinal: 1,
                threadID: thread), replay: true)
        }
        let read = await owner.beginHistoryRead()
        let fresh = try await history.openTail(header: header, base: read.base,
            bypassCache: warmer.needsRead(threadID: thread, revision: header.updatedAt))
        _ = await owner.merge(fresh, read: read)
        #expect(await gateway.itemReads == (keepsOwner ? 1 : 2))
        if coverage == .liveCheckpoint {
            let capture = UUID()
            await owner.beginObservation(capture)
            try await owner.finishObservation(capture, receipt: .init(connection: UUID(), sequence: 10), header: header,
                checkpoint: .init(turnsBackwardsCursor: nil, itemsBackwardsCursor: nil, activeTurn: nil,
                    historyUnavailable: false, liveItems: [
                        .init(turnId: "turn", item: .agentMessage(id: "answer", text: "AB"), isComplete: false)
                    ]), history: .init(turns: [], entries: [], update: nil), read: await owner.beginHistoryRead())
        }
        await sessions.synchronizeActivity([.init(threadID: thread, turnID: "turn")])
        await sessions.ingest(try GatewayEventFixture.delta("C", threadID: thread, turnID: "turn", itemID: "answer"), replay: false)
        let streaming = await owner.snapshot()
        let hasPrefix = coverage == .retained || coverage == .liveCheckpoint
        #expect(streaming.messages.map(\.text) == [hasPrefix ? "ABC" : "A"])
        #expect(streaming.messages.allSatisfy { $0.isStreaming })
        #expect(streaming.messages.map(\.canonicalTurnID) == ["turn"])
        await sessions.ingest(try event("item/completed", item: .agentMessage(id: "answer", text: "ABC"), ordinal: 1,
            threadID: thread), replay: false)
        #expect(await owner.snapshot().messages.map(\.text) == ["ABC"])
        #expect(await owner.snapshot().messages.allSatisfy { !$0.isStreaming })
        withExtendedLifetime(retained) {}
        for id in await sessions.openThreadIDs() { await sessions.invalidate(threadID: id) }
    }

    @Test func resumingAfterANewerHeaderRevisionWithoutAChangeEventReadsAuthoritatively() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let thread = "claude_resumed"
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let gateway = OpeningHistoryGateway()
        let history = GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: temporary.storage.root.appending(path: "pages")))
        let warmer = ConversationWarmer(host: OpeningHost(), conversations: sessions, history: history)
        let owner = await sessions.session(threadID: thread)
        let read = ConversationHeader.historyFixture(id: thread, updatedAt: 2)
        _ = try await history.openTail(header: read, base: nil)
        warmer.readSucceeded(threadID: thread, observation: warmer.observation(threadID: thread, revision: read.updatedAt))
        #expect(await warmer.prepareOpening(threadID: thread) === owner)
        let newer = ConversationHeader.historyFixture(id: thread, updatedAt: 3)
        #expect(!warmer.needsRead(threadID: thread, revision: read.updatedAt))
        #expect(warmer.needsRead(threadID: thread, revision: newer.updatedAt))
        let tail = await owner.beginHistoryRead()
        _ = try await history.openTail(header: newer, base: tail.base,
            bypassCache: warmer.needsRead(threadID: thread, revision: newer.updatedAt))
        #expect(await gateway.itemReads == 2)
        await sessions.invalidate(threadID: thread)
    }

    @Test func aNewOwnerDoesNotFabricateAPrefixFromAMidItemDelta() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let hostID = UUID()
        let sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
        let owner = await sessions.session(threadID: "claude_new")
        await sessions.synchronizeActivity([.init(threadID: "claude_new", turnID: "turn")])
        await sessions.ingest(try GatewayEventFixture.delta("C", threadID: "claude_new", turnID: "turn", itemID: "answer"), replay: false)
        let running = await owner.snapshot()
        #expect(running.messages.isEmpty)
        #expect(running.timelines.contains { $0.isLive })
        await sessions.ingest(try event("item/completed", item: .agentMessage(id: "answer", text: "ABC"), ordinal: 1,
            threadID: "claude_new"), replay: true)
        #expect(await owner.snapshot().messages.map(\.text) == ["ABC"])
        await sessions.invalidate(threadID: "claude_new")
    }
}

@MainActor
private final class OpeningHost: ConversationWarmingHost {
    var mayWarm: Bool { false }
    var presentedConversationIDs: Set<UUID> { [] }
    func refreshAgents(threadID: String) async {}
    func didWarm(_ snapshot: ConversationSnapshot, session: ConversationSession) {}
    var htmlVisualPreparationContext: HTMLVisualPreparationContext? { nil }
    func prepareHTMLVisuals(_ references: [HTMLVisualReference]) async -> HTMLVisualPreparationOutcome {
        .settled(stored: 0, unpreparable: 0)
    }
}

private actor OpeningHistoryGateway: CodexHistoryGateway {
    let historyHostID = "opening-host"
    private(set) var itemReads = 0
    func historyPageData(method: String, params: JSONValue) throws -> Data {
        if method == "thread/items/list" {
            itemReads += 1
            return try JSONEncoder().encode(OpeningEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(
                data: [], nextCursor: nil, backwardsCursor: nil)))
        }
        guard method == "thread/turns/list" else { throw CancellationError() }
        return try JSONEncoder().encode(OpeningEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(
            data: [.init(id: "turn", items: [], startedAt: 1, completedAt: nil, status: .inProgress, error: nil)],
            nextCursor: nil, backwardsCursor: nil)))
    }
    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse { throw CancellationError() }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw CancellationError() }
    func readThread(threadID: String, includeTurns: Bool) -> CodexAppServerV2.ThreadReadResponse { .init(thread: .historyFixture(id: threadID)) }
}

private nonisolated struct OpeningEnvelope<Value: Encodable>: Encodable {
    let result: Value
}

private actor CompletionOpeningGateway: CodexHistoryGateway {
    let historyHostID = "completion-opening-host"
    private let outcome: OpeningTailOutcome
    private var released = false
    private var tail: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    init(outcome: OpeningTailOutcome) { self.outcome = outcome }

    func waitForTail() async {
        if tail == nil { await withCheckedContinuation { arrival = $0 } }
    }

    func releaseTail() { released = true; tail?.resume(); tail = nil }

    func historyPageData(method: String, params: JSONValue) async throws -> Data {
        if method == "thread/items/list" {
            if !released { await withCheckedContinuation { tail = $0; arrival?.resume(); arrival = nil } }
            if outcome == .failure { throw URLError(.cannotConnectToHost) }
            return try JSONEncoder().encode(OpeningEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(
                data: [.init(turnId: "turn", item: .agentMessage(id: "answer", text: "A completed reply"),
                    startedAtOrdinal: 1, startedAtMs: 1_000, completedAtMs: 20_000, isComplete: true)],
                nextCursor: nil, backwardsCursor: nil)))
        }
        guard method == "thread/turns/list" else { throw CancellationError() }
        return try JSONEncoder().encode(OpeningEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(
            data: [.init(id: "turn", items: [], startedAt: 1, completedAt: outcome == .completed ? 20 : nil,
                status: outcome == .completed ? .completed : .inProgress, error: nil)],
            nextCursor: nil, backwardsCursor: nil)))
    }

    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse { throw CancellationError() }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw CancellationError() }
    func readThread(threadID: String, includeTurns: Bool) -> CodexAppServerV2.ThreadReadResponse { .init(thread: .historyFixture(id: threadID)) }
}

nonisolated enum OpeningTailOutcome: CaseIterable, Sendable { case stale, completed, failure }

private actor OpeningPause {
    private var opening: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if !released { await withCheckedContinuation { opening = $0; arrival?.resume(); arrival = nil } }
    }

    func waitForOpening() async {
        if opening == nil { await withCheckedContinuation { arrival = $0 } }
    }

    func release() { released = true; opening?.resume(); opening = nil }
}

@MainActor
private final class OpeningLifecycleSink: GatewayEventSink {
    let isRetired = false
    let acceptsConnectionReports = true
    private(set) var connected = false
    private(set) var deliveries = 0
    private let address: ConversationAddress
    private let index: ConversationIndex
    private let sessions: ConversationSessions

    init(address: ConversationAddress, index: ConversationIndex, sessions: ConversationSessions) {
        self.address = address
        self.index = index
        self.sessions = sessions
    }

    func apply(gatewayEvent event: RoutedGatewayEvent, replay: Bool) async {
        guard case .turnEvent(let event) = event else { return }
        if event.threadID == address.threadID {
            let id = await index.conversationID(for: address.threadID) ?? ChatMessage.deterministicID(for: address.threadID)
            _ = await sessions.session(conversationID: id, threadID: address.threadID)
        }
        await sessions.ingest(event, replay: replay)
        deliveries += 1
    }

    func applyTurnLifecycle(_ event: TurnScopedGatewayEvent, replay: Bool) { deliveries += 1 }
    func gatewayConnectionChanged(_ link: GatewayEventPump.Link, connection: UUID?) { connected = link == .connected }
    func gatewayConnectivityChanged(_ connectivity: GatewayConnectivity) {}
    func gatewayNetworkPathChanged() {}
    func gatewayActivityRefreshRequested() {}
    func gatewayThreadClosed(_ threadID: String, receipt: GatewayWireReceipt?) {}
    func gatewayQuestionsChanged(_ change: ServerNotification.QuestionsChanged) {}
    func defersReplay(_ event: RoutedGatewayEvent) -> Bool { false }
    func reconcile(gap: ReplayProgress.Gap) async {}
}
