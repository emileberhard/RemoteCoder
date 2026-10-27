import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct ChatHistoryReadTests {
    private let threadID = "claude_44444444-0000-0000-0000-000000000004"

    @Test(.timeLimit(.minutes(1))) func aPageReadThatOutlivesInvalidationLeavesTheReplacementSessionEmpty() async throws {
        let gateway = try await serving(entries: 60)
        await gateway.holdCursorPages()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let chat = try await open(fixture)
        let read = try #require(chat.historyEdges.load(.older))
        await gateway.waitForHeldPage()
        await chat.target.conversations.invalidate(threadID: threadID)
        await gateway.releaseHeldPage()
        await read.value
        let replacement = await chat.target.conversations.session(conversationID: chat.currentConversationID, threadID: threadID)
        #expect(await replacement.beginHistoryRead().base?.turn("t0") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func coveringTheTranscriptDefersPagingUntilItIsUncovered() async throws {
        let gateway = try await serving(entries: 60)
        await gateway.holdCursorPages()
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let workspace = fixture.workspace
        let chat = try await openPrefetching(fixture)
        workspace.setHistoryDrawerOpen(true, overlaysTranscript: true, in: workspace.keyWindow)
        #expect(chat.historyEdges.load(.older) == nil)
        await gateway.waitForHeldPage()
        let pages = await gateway.requests("thread/items/list").count
        await gateway.releaseHeldPage()
        try #require(await waitUntil { chat.historyEdges.isIdle })
        #expect(await gateway.requests("thread/items/list").count == pages)
        workspace.setHistoryDrawerOpen(false, overlaysTranscript: true, in: workspace.keyWindow)
        #expect(!chat.historyEdges.isIdle)
    }

    @Test(.timeLimit(.minutes(2))) func jumpingToTheLatestReadsTheGatewayTailEvenWhileItsPagesAreCached() async throws {
        let gateway = try await serving(entries: 2_100)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let chat = try await openFarBack(fixture)
        let before = await gateway.tailReads
        chat.historyEdges.showLatest()
        #expect(await waitUntil { await gateway.tailReads > before && chat.historyEdgeStatus[.newer] == nil })
        #expect(!chat.streamItems.endsAtNewerHistoryEdge)
    }

    @Test(.timeLimit(.minutes(2))) func aFailedJumpToTheLatestReadsTheGatewayTailAgainAfterBackgrounding() async throws {
        let gateway = try await serving(entries: 2_100)
        let fixture = await WorkspaceFixture(miniGatewayPort: try await gateway.start())
        defer { await fixture.cleanUp(); await gateway.stop() }
        let chat = try await openFarBack(fixture)
        await gateway.failTailReads(true)
        chat.historyEdges.showLatest()
        try #require(await waitUntil { chat.alert?.message != nil })
        #expect(!chat.streamItems.endsAtNewerHistoryEdge)
        await chat.target.handleScenePhaseBackground()
        await gateway.failTailReads(false)
        let before = await gateway.tailReads
        chat.historyEdges.showLatest()
        #expect(await waitUntil { await gateway.tailReads > before })
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
        await chat.target.prepareIfNeeded()
        return chat
    }

    private func serving(entries count: Int) async throws -> FakeGatewayServer {
        let gateway = try FakeGatewayServer(threadID: threadID, model: "opus")
        await gateway.serveHistory((0..<count).map { index in
            .init(turnId: "t\(index / 3)", item: .agentMessage(id: "m\(index)", text: "Message \(index)"),
                  startedAtOrdinal: Int64(index), isComplete: true)
        })
        return gateway
    }

    private func open(_ fixture: WorkspaceFixture) async throws -> ChatScreenModel {
        let chat = try await beginOpening(fixture)
        try #require(await waitUntil(timeout: .seconds(30)) { chat.loadingTranscriptID == nil && chat.activeSessionID == threadID && !chat.messages.isEmpty },
            "loading=\(chat.loadingTranscriptID ?? "none") messages=\(chat.messages.count) error=\(chat.alert?.message ?? "none")")
        return chat
    }

    private func openPrefetching(_ fixture: WorkspaceFixture) async throws -> ChatScreenModel {
        let chat = try await open(fixture)
        try #require(await waitUntil { chat.historyEdges.allowsPrefetch })
        chat.historyEdges.prefetchEarlier()
        try #require(!chat.historyEdges.isIdle)
        return chat
    }

    private func openFarBack(_ fixture: WorkspaceFixture) async throws -> ChatScreenModel {
        let chat = try await open(fixture)
        for _ in 0..<60 where !chat.streamItems.endsAtNewerHistoryEdge {
            let read = try #require(chat.historyEdges.load(.older))
            await read.value
        }
        try #require(chat.streamItems.endsAtNewerHistoryEdge)
        return chat
    }
}
