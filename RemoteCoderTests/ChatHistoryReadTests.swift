import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct ChatHistoryReadTests {
    private let threadID = "claude_44444444-0000-0000-0000-000000000004"

    @Test(.timeLimit(.minutes(1))) func aLatePageFromAnInvalidatedOwnerCannotPopulateItsReplacement() async throws {
        let fixture = TargetModelFixture()
        defer { await fixture.cleanUp() }
        let target = fixture.target
        let chat = target.makeScreen(newChat: UUID())
        chat.selectDraft(.thread(threadID))
        try #require(await chat.prepareDraft())
        chat.setActiveSessionID(threadID)
        let original = await target.conversations.session(conversationID: chat.currentConversationID, threadID: threadID)
        await chat.adopt(original)
        let gateway = HistoryGatewayFixture(threadID: threadID)
        await gateway.setHistory(.init(entries: (0..<60).map { index in
            .init(turnId: "t\(index / 3)", item: .agentMessage(id: "m\(index)", text: "Message \(index)"),
                  startedAtOrdinal: Int64(index), isComplete: true)
        }, turns: []))
        let history = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(
            directory: fixture.temporaryStorage.storage.root.appending(path: "history-pages")))
        let header = await gateway.header
        let opening = await original.beginHistoryRead()
        let tail = try await history.openTail(header: header, base: opening.base)
        await chat.applyConversationSnapshot(tail, read: opening, from: original, source: "network")
        try #require(!chat.messages.isEmpty)
        let read = await original.beginHistoryRead()
        let page = try await history.page(header: header, window: try #require(read.base), direction: .desc, priority: .foreground)

        await target.conversations.invalidate(threadID: threadID)
        let replacement = await target.conversations.session(conversationID: chat.currentConversationID, threadID: threadID)
        try #require(replacement !== original)
        await chat.adopt(replacement)
        await chat.applyConversationSnapshot(page, read: read, from: original, source: "paging")
        #expect(await replacement.beginHistoryRead().base == nil)
        #expect(chat.messages.isEmpty)

        let current = await replacement.beginHistoryRead()
        await chat.applyConversationSnapshot(tail, read: current, from: replacement, source: "network")
        #expect(chat.messages.count == 50)
        #expect(chat.messages.first?.text == "Message 10")
        #expect(chat.messages.last?.text == "Message 59")
    }

    @Test(.timeLimit(.minutes(1))) func coveringTheTranscriptDefersPagingUntilItIsUncovered() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let (chat, gateway) = try await openInProcess(fixture, entries: 240)
        defer { await gateway.releaseHeldRead() }
        await gateway.holdNextRead(.page)
        let read = try #require(chat.historyEdges.load(.older))
        await gateway.waitForHeldRead()
        let workspace = fixture.workspace
        workspace.setHistoryDrawerOpen(true, overlaysTranscript: true, in: workspace.keyWindow)
        #expect(chat.historyEdges.load(.older) == nil)
        let pages = await gateway.pageReads
        await gateway.releaseHeldRead()
        await read.value
        #expect(chat.historyEdges.isIdle)
        try #require(chat.hasHistoryEdge(.older))
        #expect(await gateway.pageReads == pages)
        workspace.setHistoryDrawerOpen(false, overlaysTranscript: true, in: workspace.keyWindow)
        #expect(!chat.historyEdges.isIdle)
        await chat.historyEdges.drain()
        #expect(await gateway.pageReads > pages)
    }

    @Test(.timeLimit(.minutes(2))) func jumpingToTheLatestReadsTheGatewayTailEvenWhileItsPagesAreCached() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let (chat, gateway) = try await openInProcess(fixture, entries: 2_100)
        try await pageFarBack(chat)
        let before = await gateway.tailReads
        chat.historyEdges.showLatest()
        await chat.historyEdges.drain()
        #expect(await gateway.tailReads > before)
        #expect(chat.historyEdgeStatus[.newer] == nil)
        #expect(!chat.streamItems.endsAtNewerHistoryEdge)
    }

    @Test(.timeLimit(.minutes(2))) func aFailedJumpToTheLatestReadsTheGatewayTailAgainAfterBackgrounding() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let (chat, gateway) = try await openInProcess(fixture, entries: 2_100)
        try await pageFarBack(chat)
        await gateway.failPages(true)
        chat.historyEdges.showLatest()
        await chat.historyEdges.drain()
        try #require(chat.alert?.message != nil)
        #expect(!chat.streamItems.endsAtNewerHistoryEdge)
        await chat.target.handleScenePhaseBackground()
        await gateway.failPages(false)
        let before = await gateway.tailReads
        chat.historyEdges.showLatest()
        await chat.historyEdges.drain()
        #expect(await gateway.tailReads > before)
        #expect(!chat.streamItems.endsAtNewerHistoryEdge)
    }

    @Test(.timeLimit(.minutes(1))) func evictionDuringOpeningPreservesFailureAndRetriesTheTail() async throws {
        let gateway = try await servingUserHistory(entries: 60)
        await gateway.holdTailPages()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldTailPage(); await fixture.cleanUp(); await gateway.stop() }
        let chat = try await beginOpening(fixture)
        await gateway.waitForHeldTailPage()
        await evictOtherThreads(chat)
        await gateway.releaseHeldTailPage()
        try #require(await waitUntil { chat.loadingTranscriptID == nil && chat.historyEdges.isIdle })
        #expect(chat.messages.isEmpty)
        #expect(chat.alert?.message != nil)
        #expect(chat.historyEdgeStatus[.newer] == .failed)
        let before = await gateway.tailReads
        chat.historyEdges.retryFailed()
        #expect(await waitUntil { await gateway.tailReads > before && !chat.messages.isEmpty && chat.historyEdges.isIdle })
        #expect(chat.historyEdgeStatus[.newer] == nil)
    }

    @Test(.timeLimit(.minutes(1))) func evictionDuringPagingRetainsTheFailedEdgeForRetry() async throws {
        let gateway = try await servingUserHistory(entries: 120)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldPage(); await fixture.cleanUp(); await gateway.stop() }
        let chat = try await open(fixture)
        await gateway.holdCursorPages()
        let read = try #require(chat.historyEdges.load(.older))
        await gateway.waitForHeldPage()
        await evictOtherThreads(chat)
        await gateway.releaseHeldPage()
        await read.value
        #expect(chat.historyEdgeStatus[.older] == .failed)
        await chat.target.handleScenePhaseBackground()
        let before = await gateway.requests("thread/items/list").count
        chat.historyEdges.retryFailed()
        #expect(await waitUntil {
            await gateway.requests("thread/items/list").count > before && chat.historyEdges.isIdle
        })
        #expect(chat.historyEdgeStatus[.older] == nil)
    }

    @Test(.timeLimit(.minutes(2))) func evictionDuringLatestRetainsRetryAfterBackgrounding() async throws {
        let gateway = try await servingUserHistory(entries: 2_100)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await gateway.releaseHeldTailPage(); await fixture.cleanUp(); await gateway.stop() }
        let chat = try await openFarBack(fixture)
        await gateway.holdTailPages()
        chat.historyEdges.showLatest()
        await gateway.waitForHeldTailPage()
        await evictOtherThreads(chat)
        await gateway.releaseHeldTailPage()
        try #require(await waitUntil { chat.historyEdges.isIdle })
        #expect(chat.alert?.message != nil)
        #expect(!chat.streamItems.endsAtNewerHistoryEdge)
        await chat.target.handleScenePhaseBackground()
        let before = await gateway.tailReads
        chat.historyEdges.retryFailed()
        #expect(await waitUntil { await gateway.tailReads > before && chat.historyEdges.isIdle })
        #expect(!chat.streamItems.endsAtNewerHistoryEdge)
    }

    private func evictOtherThreads(_ chat: ChatScreenModel) async {
        for index in 0..<65 { await chat.target.historyService.invalidate(threadID: "unrelated-\(index)") }
    }

    private func servingUserHistory(entries count: Int) async throws -> FakeGatewayServer {
        let gateway = try FakeGatewayServer(threadID: threadID, model: "opus")
        await gateway.serveHistory((0..<count).map { index in
            .init(turnId: "t\(index)", item: .userMessage(id: "u\(index)", content: [.text(text: "Message \(index)", textElements: [])]),
                  startedAtOrdinal: Int64(index), isComplete: true)
        })
        return gateway
    }

    private func beginOpening(_ fixture: WorkspaceFixture) async throws -> ChatScreenModel {
        let workspace = fixture.workspace
        let chat = try #require(workspace.screen(for: fixture.mini.id))
        await chat.target.conversationList.record(try fixture.thread(threadID, updatedAt: 1))
        workspace.selectConversation(at: .init(hostID: fixture.mini.id, threadID: threadID))
        try #require(workspace.selectedScreen === chat)
        Task { await chat.target.prepareIfNeeded() }
        return chat
    }

    private func openInProcess(_ fixture: WorkspaceFixture, entries count: Int) async throws
        -> (ChatScreenModel, HistoryGatewayFixture) {
        let chat = try #require(fixture.workspace.selectedScreen)
        chat.selectDraft(.thread(threadID))
        try #require(await chat.prepareDraft())
        chat.setActiveSessionID(threadID)
        let session = await chat.target.conversations.session(conversationID: chat.currentConversationID, threadID: threadID)
        await chat.adopt(session)
        let gateway = HistoryGatewayFixture(threadID: threadID)
        await gateway.setHistory(.init(entries: (0..<count).map { index in
            .init(turnId: "t\(index / 3)", item: .agentMessage(id: "m\(index)", text: "Message \(index)"),
                  startedAtOrdinal: Int64(index), isComplete: true)
        }, turns: []))
        let history = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(
            directory: fixture.temporaryStorage.storage.root.appending(path: "history-pages")))
        chat.historyEdges = HistoryEdgeReader(host: chat, historyService: history,
            conversations: chat.target.conversations, networkPolicy: HistoryNetworkPolicy())
        let read = await session.beginHistoryRead()
        let tail = try await history.openTail(header: await gateway.header, base: read.base)
        await chat.applyConversationSnapshot(tail, read: read, from: session, source: "network")
        try #require(!chat.messages.isEmpty)
        return (chat, gateway)
    }

    private func open(_ fixture: WorkspaceFixture) async throws -> ChatScreenModel {
        let chat = try await beginOpening(fixture)
        try #require(await waitUntil { chat.loadingTranscriptID == nil && chat.activeSessionID == threadID && !chat.messages.isEmpty },
            "loading=\(chat.loadingTranscriptID ?? "none") messages=\(chat.messages.count) error=\(chat.alert?.message ?? "none")")
        return chat
    }

    private func openFarBack(_ fixture: WorkspaceFixture) async throws -> ChatScreenModel {
        let chat = try await open(fixture)
        try await pageFarBack(chat)
        return chat
    }

    private func pageFarBack(_ chat: ChatScreenModel) async throws {
        for _ in 0..<60 where !chat.streamItems.endsAtNewerHistoryEdge {
            let read = try #require(chat.historyEdges.load(.older))
            await read.value
        }
        try #require(chat.streamItems.endsAtNewerHistoryEdge)
    }
}
