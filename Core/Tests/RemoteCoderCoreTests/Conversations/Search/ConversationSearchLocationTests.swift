import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationSearchLocationTests {
    @Test func locatedHistoryReplacesAnExistingTailAndKeepsBothPagingDirections() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.gateway.setHistory(HistoryGatewayFixture.workingHistory(turns: 100, ordinals: true))
        await fixture.gateway.setLocateReply(reply(items: "30", turns: "10", turn: "t10", item: "u10"))
        let header = fixture.gateway.header
        let tail = try await fixture.service.openTail(header: header, base: nil)
        let opened = try await fixture.service.openSearchHit(header: header, itemKey: "key", fallback: .openTail(base: tail.window, bypassCache: false))
        let positioned = try #require(opened.snapshot)
        #expect(positioned.window.turns.first?.id == "t10")
        #expect(positioned.window.turns.first?.entries.first?.item.id == "u10")
        #expect(positioned.window.older != nil && positioned.window.newer != nil)
        let checkpoint = ConversationCheckpointStore(hostID: UUID(), directory: fixture.directory.appending(path: "checkpoints"), primaryBudgetBytes: 8_192)
        let session = await ConversationSession.make(conversationID: UUID(), threadID: header.id, checkpoints: checkpoint)
        _ = await session.merge(tail, read: session.beginHistoryRead())
        let snapshot = await session.merge(positioned, read: session.beginHistoryRead())
        let row = try #require(await opened.location?.reveal(in: snapshot.items)?.rowID)
        #expect(row == snapshot.items.first { if case .message(let m) = $0 { m.canonicalItemID == "u10" } else { false } }?.id)
        let older = try await fixture.service.page(header: header, window: positioned.window, direction: .desc, priority: .foreground)
        #expect(older.window.turns.first?.id == "t0")
        let newer = try await fixture.service.page(header: header, window: positioned.window, direction: .asc, priority: .foreground)
        #expect(newer.window.turns.last?.id != positioned.window.turns.last?.id)
    }

    @Test func aLocatedWindowKeepsAnActiveTurnBehindTheHistoryGap() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.gateway.setHistory(HistoryGatewayFixture.workingHistory(turns: 100, ordinals: true))
        await fixture.gateway.setLocateReply(reply(items: "30", turns: "10", turn: "t10", item: "u10"))
        let header = fixture.gateway.header
        var state = ConversationState(conversationID: UUID(), threadID: header.id)
        let tail = try await fixture.service.openTail(header: header, base: nil)
        state.merge(tail, read: state.beginHistoryRead())
        #expect(state.hasVerifiedNewestHistory)
        state.activity(turnID: "live", active: true)
        state.apply(try GatewayEventFixture.item("item/started", item: .agentMessage(id: "answer", text: "A"),
            threadID: header.id, turnID: "live", ordinal: 310, startedAtMs: 1_000, completedAtMs: 2_000))
        let initial = ConversationProjection.project(state)
        #expect(initial.messages.contains { $0.canonicalTurnID == "live" && $0.isStreaming && $0.text == "A" })
        #expect(initial.timelines.contains { $0.isLive })

        let read = state.beginHistoryRead()
        let located = try await fixture.service.openSearchHit(header: header, itemKey: "key", fallback: .keepCurrentWindow)
        state.merge(try #require(located.snapshot), read: read)
        state.apply(try GatewayEventFixture.delta("B", threadID: header.id, turnID: "live", itemID: "answer"))

        let historical = ConversationProjection.project(state)
        #expect(historical.messages.contains { $0.canonicalItemID == "u10" })
        #expect(!historical.messages.contains { $0.canonicalTurnID == "live" || $0.canonicalTurnID == "t99" })
        #expect(!historical.timelines.contains { $0.isLive })
        #expect(historical.items.endsAtNewerHistoryEdge)
        #expect(!state.hasVerifiedNewestHistory)
        #expect(state.turns["live"]?.items["answer"]?.value == .agentMessage(id: "answer", text: "AB"))

        let jump = state.beginHistoryRead()
        state.merge(try await fixture.service.openTail(header: header, base: jump.base, bypassCache: true), read: jump)
        let latest = ConversationProjection.project(state)
        #expect(latest.messages.contains { $0.canonicalTurnID == "live" && $0.isStreaming && $0.text == "AB" })
        #expect(latest.timelines.contains { $0.isLive })
        #expect(!latest.items.endsAtNewerHistoryEdge)
        #expect(state.hasVerifiedNewestHistory)
    }

    @Test func anExactItemBeyondTheInitialPageIsLoadedWithoutReadingTheTail() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.gateway.setHistory(HistoryGatewayFixture.workingHistory(turns: 100, ordinals: true))
        await fixture.gateway.setLocateReply(reply(items: "0", turns: "0", turn: "t25", item: "a25"))
        let opened = try await fixture.service.openSearchHit(header: fixture.gateway.header, itemKey: "key", fallback: .openTail(base: nil, bypassCache: false))
        #expect(opened.snapshot?.window.turns.contains { $0.entries.contains { $0.item.id == "a25" } } == true)
        #expect(await fixture.gateway.tailReads == 0)
    }

    @Test(arguments: ["failed", "unknown", "wrong-thread", "invalid-cursor"])
    func unavailableLocationsFallBackToTheOrdinaryTail(_ failure: String) async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        switch failure {
        case "failed": break
        case "unknown": await fixture.gateway.setLocateReply(reply(items: nil, turns: nil, turn: nil, item: nil))
        case "wrong-thread": await fixture.gateway.setLocateReply(reply(items: "0", turns: "0", turn: "t0", item: "u0", thread: "other"))
        default:
            await fixture.gateway.setLocateReply(reply(items: "bad", turns: nil, turn: "t0", item: nil))
            await fixture.gateway.rejectCursor("bad")
        }
        let opened = try await fixture.service.openSearchHit(header: fixture.gateway.header, itemKey: "key", fallback: .openTail(base: nil, bypassCache: false))
        let tail = try #require(opened.snapshot)
        #expect(tail.window.newer == nil)
        #expect(tail.window.turns.last?.id == "t19")
        #expect(await fixture.gateway.tailReads == 1)
    }

    @Test func aCursorlessTurnInAnAlreadyOpenConversationKeepsItsWindow() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.gateway.setLocateReply(reply(items: nil, turns: nil, turn: "t1", item: nil))
        let opened = try await fixture.service.openSearchHit(header: fixture.gateway.header, itemKey: "key", fallback: .keepCurrentWindow)
        #expect(opened.snapshot == nil)
        #expect(opened.location?.turnId == "t1")
        #expect(await fixture.gateway.pageReads == 0)
    }

    @Test(arguments: [true, false])
    func cancelledAndInvalidatedLocateRepliesNeverOpenHistory(_ cancel: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.gateway.setLocateReply(reply(items: "0", turns: "0", turn: "t0", item: "u0"))
        await fixture.gateway.holdNextRead(.locate)
        let task = Task { try await fixture.service.openSearchHit(header: fixture.gateway.header, itemKey: "key", fallback: .openTail(base: nil, bypassCache: false)) }
        await fixture.gateway.waitForHeldRead()
        if cancel { task.cancel() } else { await fixture.service.invalidate(threadID: "fixture") }
        await fixture.gateway.releaseHeldRead()
        do { _ = try await task.value; Issue.record("a stale location opened history") } catch {}
        #expect(await fixture.gateway.pageReads == 0)
    }

    @Test func rowResolutionUsesExactCanonicalIdentityAndFallsBackOnlyToTheKnownTurn() async {
        let first = ChatStreamItem.message(ChatMessage(role: .user, text: "first", canonicalTurnID: "turn", canonicalItemID: "first"))
        let target = ChatStreamItem.message(ChatMessage(role: .codex, text: "target", canonicalTurnID: "turn", canonicalItemID: "target"))
        let exact = ConversationSearchLocation(threadId: "fixture", turnId: "turn", turnsCursor: nil, itemsCursor: nil, itemId: "target")
        #expect(await exact.reveal(in: [first, target])?.rowID == target.id)
        let turn = ConversationSearchLocation(threadId: "fixture", turnId: "turn", turnsCursor: nil, itemsCursor: nil, itemId: "missing")
        #expect(await turn.reveal(in: [first, target])?.rowID == first.id)
        let unknown = ConversationSearchLocation(threadId: "fixture", turnId: nil, turnsCursor: nil, itemsCursor: nil, itemId: nil)
        #expect(await unknown.reveal(in: [first, target])?.rowID == nil)
    }

    @Test func aLocatedToolItemUsesItsExactActivityRow() async {
        let event = JobTimelineEvent(id: "gw-fixture-t1-tool", sequence: 1, kind: .toolResult,
            title: "Command", subtitle: nil, timestamp: nil, details: [])
        let group = JobTimeline(id: "segment", startedAt: nil, anchorDate: .distantPast, completedAt: nil,
            isLive: false, isExpanded: false, events: [event])
        let location = ConversationSearchLocation(threadId: "fixture", turnId: "t1", turnsCursor: nil, itemsCursor: nil, itemId: "tool")
        #expect(await location.reveal(in: [.timeline(group)]) == .init(rowID: "activity-gw-fixture-t1-tool", groupToExpand: "segment"))
    }

    private func reply(items: String?, turns: String?, turn: String?, item: String?, thread: String = "fixture") -> ConversationSearchLocation {
        ConversationSearchLocation(threadId: thread, turnId: turn, turnsCursor: turns, itemsCursor: items, itemId: item)
    }

    private struct Fixture {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let gateway = HistoryGatewayFixture()
        let service: GatewayHistoryService
        init() { service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory)) }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
