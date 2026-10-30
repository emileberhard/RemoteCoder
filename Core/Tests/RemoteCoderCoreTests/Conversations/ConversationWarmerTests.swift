import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ConversationWarmerTests {
    private static let digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private static let now = Int64(Date.now.timeIntervalSince1970)

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

    @Test func coveredOpeningHistoryIsSkippedWhilePreparationIsUnavailable() async {
        let fixture = WarmingFixture()
        defer { fixture.cleanUp() }
        let warmer = fixture.warmer()
        let header = ConversationHeader.historyFixture(id: "opened")
        warmer.readSucceeded(threadID: header.id, observation: warmer.observation(threadID: header.id, revision: header.updatedAt))

        fixture.host.htmlVisualPreparationContext = nil
        #expect(!warmer.needsWarm(header))
        await warmer.warm([header], hot: [], agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 0)
        #expect(fixture.host.prepared.isEmpty)
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
struct ConversationWarmingCoverageTests {
    private static let theme = HTMLVisualTheme(fontSize: 17, text: "#000", secondaryText: "#333", background: "#fff",
        surface: "#eee", accent: "#00f", isDark: false)
    private static let portrait = HTMLVisualPreparationContext(width: 402, theme: theme)
    private static let landscape = HTMLVisualPreparationContext(width: 874, theme: theme)
    private static let firstDigest = String(repeating: "a", count: 64)
    private static let secondDigest = String(repeating: "b", count: 64)
    private static let threads = ["first", "second", "plain"].map { ConversationHeader.historyFixture(id: $0) }

    private static func fixture() -> WarmingFixture {
        WarmingFixture(gateway: VisualTailGateway(text: { [firstDigest, secondDigest] threadID in
            switch threadID {
            case "first": "![First](rc-visual:\(firstDigest))"
            case "second": "![Second](rc-visual:\(secondDigest))"
            default: "No visual in this answer."
            }
        }))
    }

    @Test func closingAnUnchangedDrawerDoesNoWorkAfterHistoryAndVisualCoverage() async {
        let fixture = Self.fixture()
        defer { fixture.cleanUp() }
        let warmer = fixture.warmer()

        fixture.host.htmlVisualPreparationContext = nil
        await warmer.warm(Self.threads, hot: [], agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 3)
        #expect(fixture.host.prepared.isEmpty)
        #expect(Self.threads.filter(warmer.needsWarm).isEmpty)

        fixture.host.htmlVisualPreparationContext = Self.portrait
        await warmer.warm(Self.threads.filter(warmer.needsWarm), hot: [], agentThreadIDs: [])
        #expect(fixture.host.prepared.flatMap { $0.map(\.digest) } == [Self.firstDigest, Self.secondDigest])
        fixture.host.htmlVisualPreparationContext = nil
        #expect(Self.threads.filter(warmer.needsWarm).isEmpty)
        fixture.host.htmlVisualPreparationContext = Self.portrait
        #expect(Self.threads.filter(warmer.needsWarm).isEmpty)
        await warmer.warm(Self.threads, hot: [], agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 3)
        #expect(fixture.host.prepared.count == 2)
    }

    @Test(arguments: [false, true])
    func contextChangesReuseVisualReferencesEvenWhenStoredTailsAreGone(hot: Bool) async {
        let fixture = Self.fixture()
        defer { fixture.cleanUp() }
        let history = fixture.history()
        let warmer = ConversationWarmer(host: fixture.host, conversations: fixture.sessions, history: history)
        let hotIDs: Set<String> = hot ? ["first", "second"] : []

        fixture.host.htmlVisualPreparationContext = Self.portrait
        await warmer.warm(Self.threads, hot: hotIDs, agentThreadIDs: [])
        await history.invalidateAll()
        fixture.host.htmlVisualPreparationContext = Self.landscape
        #expect(Self.threads.filter(warmer.needsWarm).map(\.id) == ["first", "second"])
        await warmer.warm(Self.threads.filter(warmer.needsWarm), hot: hotIDs, agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 3)
        #expect(fixture.host.prepared.flatMap { $0.map(\.digest) }
            == [Self.firstDigest, Self.secondDigest, Self.firstDigest, Self.secondDigest])
        #expect(fixture.host.preparedContexts == [Self.portrait, Self.portrait, Self.landscape, Self.landscape])
        #expect(Self.threads.filter(warmer.needsWarm).isEmpty)
    }

    @Test func aFirstWarmCompletingWhileAnotherThreadStreamsIsRecorded() async {
        let fixture = Self.fixture()
        defer { fixture.cleanUp() }
        fixture.host.htmlVisualPreparationContext = Self.portrait
        await fixture.warmer().warm(Self.threads, hot: [], agentThreadIDs: [])

        let relaunched = fixture.warmer()
        fixture.host.onPrepare = { relaunched.changed("streaming-elsewhere") }
        await relaunched.warm(Self.threads, hot: [], agentThreadIDs: [])
        #expect(Self.threads.filter(relaunched.needsWarm).isEmpty)
        await relaunched.warm(Self.threads.filter(relaunched.needsWarm), hot: [], agentThreadIDs: [])
        #expect(await fixture.gateway.itemReads == 3)
        #expect(fixture.host.prepared.count == 4)
    }

    @Test(arguments: [HTMLVisualPreparationOutcome.incomplete(missing: 1), .interrupted])
    func unfinishedPreparationRetainsReferencesWithoutClaimingVisualCoverage(outcome: HTMLVisualPreparationOutcome) async {
        let fixture = Self.fixture()
        defer { fixture.cleanUp() }
        let history = fixture.history()
        let warmer = ConversationWarmer(host: fixture.host, conversations: fixture.sessions, history: history)
        let header = Self.threads[0]
        fixture.host.outcomes = [outcome]
        await warmer.warm([header], hot: [], agentThreadIDs: [])
        #expect(warmer.needsWarm(header))
        await history.invalidateAll()
        await warmer.warm([header].filter(warmer.needsWarm), hot: [], agentThreadIDs: [])
        #expect(!warmer.needsWarm(header))
        #expect(await fixture.gateway.itemReads == 1)
        #expect(fixture.host.prepared.flatMap { $0.map(\.digest) } == [Self.firstDigest, Self.firstDigest])
    }
}

@MainActor
private struct WarmingFixture {
    let temporary = TemporaryHostStorage()
    let sessions: ConversationSessions
    let gateway: VisualTailGateway
    let host = WarmingHost()

    init(gateway: VisualTailGateway = VisualTailGateway(text: "Compare ![Chart](rc-visual:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855) and ![Chart](rc-visual:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855)")) {
        self.gateway = gateway
        let hostID = UUID()
        sessions = ConversationSessions(hostID: hostID,
            sessionIndex: ConversationIndex(hostID: hostID, storage: temporary.storage),
            contentSubscriptions: RecordingContentSubscriptions(), storage: temporary.storage)
    }

    func warmer() -> ConversationWarmer {
        ConversationWarmer(host: host, conversations: sessions, history: history())
    }

    func history() -> GatewayHistoryService {
        GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: temporary.storage.root.appending(path: "pages"), freshnessInterval: 0))
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
    private(set) var preparedContexts: [HTMLVisualPreparationContext?] = []
    func refreshAgents(threadID: String) async {}
    func didWarm(_ snapshot: ConversationSnapshot, session: ConversationSession) {}
    func prepareHTMLVisuals(_ references: [HTMLVisualReference]) async -> HTMLVisualPreparationOutcome {
        prepared.append(references)
        preparedContexts.append(htmlVisualPreparationContext)
        onPrepare?()
        return outcomes.isEmpty ? .settled(stored: references.count, unpreparable: 0) : outcomes.removeFirst()
    }
}

private actor VisualTailGateway: CodexHistoryGateway {
    let historyHostID = "warming-host"
    let text: @Sendable (String) -> String
    private(set) var itemReads = 0

    init(text: String) { self.init(text: { _ in text }) }

    init(text: @escaping @Sendable (String) -> String) {
        self.text = text
    }

    func historyPageData(method: String, params: JSONValue) throws -> Data {
        if method == "thread/items/list" {
            itemReads += 1
            let threadID = params.objectValue?["threadId"]?.stringValue ?? ""
            return try JSONEncoder().encode(WarmingEnvelope(result: CodexAppServerV2.ThreadItemsListResponse(
                data: [.init(turnId: "turn", item: .agentMessage(id: "answer", text: text(threadID)), startedAtOrdinal: 1, isComplete: true)],
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
