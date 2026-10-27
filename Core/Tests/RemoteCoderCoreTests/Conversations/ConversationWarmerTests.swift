import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ConversationWarmerTests {
    private static let digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private static let now = Int64(Date.now.timeIntervalSince1970)

    @Test func theRankedShortlistDoesNotAdvancePastFiveAcrossRepeatedPasses() async throws {
        let fixture = WarmingFixture()
        defer { fixture.cleanUp() }
        fixture.host.htmlVisualPreparationContext = nil
        let warmer = fixture.warmer()
        var ranked = (0..<150).map { ConversationHeader.historyFixture(id: "rank-\($0)", updatedAt: Self.now - Int64($0)) }
        let hot = Set(ranked.prefix(2).map(\.id))
        for _ in 0..<4 {
            await warmer.warm(warmer.candidates(in: ranked), hot: hot, agentThreadIDs: [])
        }
        #expect(await fixture.gateway.itemReads == 5)
        #expect(warmer.candidates(in: ranked).isEmpty)
        #expect(await fixture.sessions.existingSession(threadID: ranked[0].id) != nil)
        #expect(await fixture.sessions.existingSession(threadID: ranked[5].id) == nil)

        ranked[2] = .historyFixture(id: ranked[2].id, updatedAt: Self.now + 1)
        ranked[5] = .historyFixture(id: ranked[5].id, updatedAt: Self.now + 1)
        #expect(warmer.candidates(in: ranked).map(\.id) == [ranked[2].id])
        await warmer.warm(warmer.candidates(in: ranked), hot: hot, agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 6)
        #expect(warmer.candidates(in: ranked).isEmpty)

        let promoted = ranked.remove(at: 5)
        ranked.insert(promoted, at: 0)
        #expect(warmer.candidates(in: ranked).map(\.id) == [ranked[0].id])
        await warmer.warm(warmer.candidates(in: ranked), hot: hot, agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 7)
    }

    @Test func anUnchangedConversationIsReadOnceAcrossPassesAndLaunches() async throws {
        let fixture = WarmingFixture()
        defer { fixture.cleanUp() }
        let header = ConversationHeader.historyFixture(id: "unopened")
        let warmer = fixture.warmer()

        await warmer.warm([header].filter(warmer.needsWarm), hot: [], agentThreadIDs: [])
        await warmer.warm([header].filter(warmer.needsWarm), hot: [], agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 1)
        #expect(fixture.host.prepared.map { $0.map(\.digest) } == [[Self.digest]])
        #expect(await fixture.sessions.existingSession(threadID: header.id) == nil)

        let relaunched = fixture.warmer()
        await relaunched.warm([header].filter(relaunched.needsWarm), hot: [], agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 1)
        #expect(fixture.host.prepared.count == 2)

        let changed = ConversationHeader.historyFixture(id: "unopened", updatedAt: Self.now + 60)
        await relaunched.warm([changed].filter(relaunched.needsWarm), hot: [], agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 2)
    }

    @Test func unsettledPreparationIsRetriedFromTheStoredTailUntilItSettles() async throws {
        let fixture = WarmingFixture()
        defer { fixture.cleanUp() }
        let (first, second) = (ConversationHeader.historyFixture(id: "first"), ConversationHeader.historyFixture(id: "second"))
        let warmer = fixture.warmer()

        fixture.host.outcomes = [.incomplete(missing: 1), .settled(stored: 1, unpreparable: 0)]
        await warmer.warm([first, second].filter(warmer.needsWarm), hot: [], agentThreadIDs: [])
        #expect([first, second].filter(warmer.needsWarm).map(\.id) == ["first"])

        fixture.host.outcomes = [.interrupted]
        await warmer.warm([first, second].filter(warmer.needsWarm), hot: [], agentThreadIDs: [])
        #expect([first, second].filter(warmer.needsWarm).map(\.id) == ["first"])

        await warmer.warm([first, second].filter(warmer.needsWarm), hot: [], agentThreadIDs: [])
        #expect([first, second].filter(warmer.needsWarm).isEmpty)
        #expect(await fixture.gateway.itemReads == 2)
        #expect(fixture.host.prepared.map(\.count) == [1, 1, 1, 1])
    }

    @Test(arguments: [false, true])
    func unavailablePreparationWarmsHistoryAndResumesVisualsFromStoredTails(hot: Bool) async throws {
        let fixture = WarmingFixture()
        defer { fixture.cleanUp() }
        let (first, second) = (ConversationHeader.historyFixture(id: "first"), ConversationHeader.historyFixture(id: "second"))
        let warmer = fixture.warmer()
        let hotIDs: Set<String> = hot ? [first.id, second.id] : []

        fixture.host.htmlVisualPreparationContext = nil
        await warmer.warm([first, second].filter(warmer.needsWarm), hot: hotIDs, agentThreadIDs: [])
        #expect(fixture.host.prepared.isEmpty)
        #expect([first, second].filter(warmer.needsWarm).isEmpty)

        await warmer.warm([first, second].filter(warmer.needsWarm), hot: hotIDs, agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 2)
        #expect(fixture.host.prepared.isEmpty)

        fixture.host.htmlVisualPreparationContext = HTMLVisualPreparationContext(width: 320, theme: HTMLVisualTheme(fontSize: 17,
            text: "#000", secondaryText: "#333", background: "#fff", surface: "#eee", accent: "#00f", isDark: false))
        #expect([first, second].filter(warmer.needsWarm).map(\.id) == ["first", "second"])
        await warmer.warm([first, second].filter(warmer.needsWarm), hot: hotIDs, agentThreadIDs: [])
        #expect([first, second].filter(warmer.needsWarm).isEmpty)
        #expect(await fixture.gateway.itemReads == 2)
        #expect(fixture.host.prepared.map { $0.map(\.digest) } == [[Self.digest], [Self.digest]])
    }

    @Test func cancellationAfterPreparationCannotClaimCoverageOrContinueThePass() async throws {
        let fixture = WarmingFixture()
        defer { fixture.cleanUp() }
        let first = ConversationHeader.historyFixture(id: "first")
        let second = ConversationHeader.historyFixture(id: "second")
        let warmer = fixture.warmer()
        var pass: Task<Void, Never>?
        fixture.host.onPrepare = { pass?.cancel() }
        pass = Task { await warmer.warm([first, second], hot: [], agentThreadIDs: []) }
        await pass?.value
        #expect(warmer.needsWarm(first))
        #expect(warmer.needsWarm(second))
        #expect(await fixture.gateway.itemReads == 1)

        fixture.host.onPrepare = nil
        await warmer.warm([first, second].filter(warmer.needsWarm), hot: [], agentThreadIDs: [])
        #expect(!warmer.needsWarm(first) && !warmer.needsWarm(second))
        #expect(await fixture.gateway.itemReads == 2)
    }

    @Test func aNewerHeaderRevisionIsReadAgainEvenWhenTheStoredTailLooksFresh() async throws {
        let fixture = WarmingFixture()
        defer { fixture.cleanUp() }
        let warmer = fixture.warmer()
        let read = ConversationHeader.historyFixture(id: "t", updatedAt: Self.now - 100)

        fixture.host.outcomes = [.interrupted]
        await warmer.warm([read], hot: [], agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 1)

        let newer = ConversationHeader.historyFixture(id: "t", updatedAt: Self.now - 50)
        await warmer.warm([newer].filter(warmer.needsWarm), hot: [], agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 2)
        #expect([newer].filter(warmer.needsWarm).isEmpty)
    }

    @Test func aNewPreparationContextReplacesEarlierCoverageWithoutAnotherRead() async throws {
        let fixture = WarmingFixture()
        defer { fixture.cleanUp() }
        let warmer = fixture.warmer()
        let header = ConversationHeader.historyFixture(id: "t")
        let theme = HTMLVisualTheme(fontSize: 17, text: "#000", secondaryText: "#333", background: "#fff",
            surface: "#eee", accent: "#00f", isDark: false)

        fixture.host.htmlVisualPreparationContext = HTMLVisualPreparationContext(width: 320, theme: theme)
        await warmer.warm([header], hot: [], agentThreadIDs: [])
        #expect([header].filter(warmer.needsWarm).isEmpty)

        fixture.host.htmlVisualPreparationContext = HTMLVisualPreparationContext(width: 640, theme: theme)
        #expect([header].filter(warmer.needsWarm).count == 1)
        await warmer.warm([header], hot: [], agentThreadIDs: [])
        #expect([header].filter(warmer.needsWarm).isEmpty)
        #expect(await fixture.gateway.itemReads == 1)
        #expect(fixture.host.prepared.count == 2)
    }
}

@MainActor
private struct WarmingFixture {
    let temporary = TemporaryHostStorage()
    let sessions: ConversationSessions
    let gateway = VisualTailGateway(text: "Compare ![Chart](rc-visual:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855) and ![Chart](rc-visual:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855)")
    let host = WarmingHost()

    init() {
        let hostID = UUID()
        sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
    }

    func warmer() -> ConversationWarmer {
        ConversationWarmer(host: host, conversations: sessions, history: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: temporary.storage.root.appending(path: "pages"))))
    }

    func cleanUp() { temporary.cleanUp() }
}

@MainActor
private final class WarmingHost: ConversationWarmingHost {
    var mayWarm: Bool { true }
    var presentedConversationIDs: Set<UUID> { [] }
    var htmlVisualPreparationContext: HTMLVisualPreparationContext? = HTMLVisualPreparationContext(width: 320,
        theme: HTMLVisualTheme(fontSize: 17, text: "#000", secondaryText: "#333", background: "#fff",
            surface: "#eee", accent: "#00f", isDark: false))
    var outcomes: [HTMLVisualPreparationOutcome] = []
    var onPrepare: (@MainActor () -> Void)?
    private(set) var prepared: [[HTMLVisualReference]] = []
    func refreshAgents(threadID: String) async {}
    func didWarm(_ snapshot: ConversationSnapshot, session: ConversationSession) {}
    func prepareHTMLVisuals(_ references: [HTMLVisualReference]) async -> HTMLVisualPreparationOutcome {
        prepared.append(references)
        onPrepare?()
        return outcomes.isEmpty ? .settled(stored: references.count, unpreparable: 0) : outcomes.removeFirst()
    }
}

private actor VisualTailGateway: CodexHistoryGateway {
    let historyHostID = "warming-host"
    let text: String
    private(set) var itemReads = 0

    init(text: String) { self.text = text }

    func historyPageData(method: String, params: JSONValue) throws -> Data {
        if method == "thread/items/list" {
            itemReads += 1
            return try JSONEncoder().encode(WarmingEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(
                data: [.init(turnId: "turn", item: .agentMessage(id: "answer", text: text), startedAtOrdinal: 1, isComplete: true)],
                nextCursor: nil, backwardsCursor: nil)))
        }
        guard method == "thread/turns/list" else { throw CancellationError() }
        return try JSONEncoder().encode(WarmingEnvelope(result: CodexAppServerV2.ThreadTurnsListResponse(
            data: [.init(id: "turn", items: [], startedAt: 1, completedAt: 2, status: .completed, error: nil)],
            nextCursor: nil, backwardsCursor: nil)))
    }
    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) throws -> CodexAppServerV2.ThreadListResponse { throw CancellationError() }
    func listClaudeThreads(limit: Int, cursor: String?) throws -> CodexAppServerV2.ThreadListResponse { throw CancellationError() }
    func readThread(threadID: String, includeTurns: Bool) -> CodexAppServerV2.ThreadReadResponse { .init(thread: .historyFixture(id: threadID)) }
}

private nonisolated struct WarmingEnvelope<Value: Encodable>: Encodable {
    let result: Value
}
