import Foundation
import Synchronization
import Testing
@testable import RemoteCoder

struct HistoryServiceTests {
    @MainActor @Test func retiredHeaderReadsRejectASuccessfulHeldResponseAndKeepThePersistedRevision() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let kept = ConversationHeader(try header("kept", time: 1))
        let late = try header("late", time: 2)
        await gateway.setCodexHeaders([late])
        await gateway.holdNextRead(.list)
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        await store.save(snapshot: .init(threads: [kept], lastSuccessfulRefreshAt: nil, revision: 1))
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: store,
            marksStore: ConversationMarksStore(directory: directory), defaults: temporary.defaults)
        let loading = Task { await model.loadOlder(query: "", including: { _ in true }) }
        await gateway.waitForHeldRead()
        model.retireHeaderReads()
        #expect(!loading.isCancelled)
        await gateway.releaseHeldRead()
        await loading.value
        #expect(model.threads == [kept])
        let reloaded = await ConversationHeaderStore(hostID: hostID, directory: directory).load()
        #expect(reloaded.threads == [kept])
        #expect(reloaded.revision == 1)
        #expect(model.errorMessage == nil)
    }

    @MainActor @Test func partialRecentCoverageReopensAnExhaustedProviderWithoutLosingItsOldRows() async throws {
        let hostID = UUID()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        await gateway.setCodexHeaders([])
        let old = try (0..<50).map { try header("claude_old-\($0)", time: 1_000 - $0) }
        await gateway.setClaudeHeaders(old)
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: ConversationHeaderStore(hostID: hostID, directory: directory),
            marksStore: ConversationMarksStore(directory: directory), defaults: temporary.defaults)
        await model.refresh()
        #expect(!model.canLoadOlder(query: ""))
        for _ in 0..<2 { await model.loadOlder(query: "claude", including: { _ in true }) }
        #expect(!model.canLoadOlder(query: "claude"))
        let new = try (0..<61).map { try header("claude_new-\($0)", time: 2_000 - $0) }
        await gateway.setClaudeHeaders(new + old)
        await model.refresh(reason: "stale-auto")
        #expect(model.canLoadOlder(query: ""))
        #expect(model.canLoadOlder(query: "claude"))
        #expect(model.header(id: new[60].id) == nil)
        #expect(Set(old.map(\.id)).isSubset(of: Set(model.threads.map(\.id))))
        for _ in 0..<2 { await model.loadOlder(query: "", including: { _ in true }) }
        #expect(model.header(id: new[60].id) != nil)
        #expect(!model.canLoadOlder(query: ""))
    }

    @MainActor @Test(arguments: [false, true])
    func incrementalRefreshPreservesOlderAndSearchProgress(_ searching: Bool) async throws {
        let hostID = UUID()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        await gateway.setCodexHeaders([])
        let headers = try (0..<600).map { try ThreadFixture.basic("claude_\($0)", updatedAt: Int64(2_000 - $0), preview: "A") }
        await gateway.setClaudeHeaders(headers.map { CodexAppServerV2.ThreadReadResponse($0).thread })
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: ConversationHeaderStore(hostID: hostID, directory: directory),
            marksStore: ConversationMarksStore(directory: directory), defaults: temporary.defaults)
        await model.refresh()
        let query = searching ? "A" : ""
        for _ in 0..<2 { await model.loadOlder(query: query, including: { _ in true }) }
        let kept = Set(model.threads.map(\.id))
        let boundary = try #require(await gateway.claudeCursors.last)
        let limit = try #require(await gateway.claudeLimits.last)
        let expected = (boundary.flatMap(Int.init) ?? 0) + limit
        await model.refresh(reason: "stale-auto")
        #expect(kept.isSubset(of: Set(model.threads.map(\.id))))
        let before = await gateway.claudeCursors.count
        for _ in 0..<2 { await model.loadOlder(query: query, including: { _ in true }) }
        let continued = await gateway.claudeCursors
        try #require(continued.count > before)
        #expect(continued[before] == String(expected))
    }

    @MainActor @Test(arguments: [HistoryGatewayFixture.HeldRead.header, .classification])
    func suspendedHeaderRecoveryCannotReplaceNewerNamesAndCompletion(_ pause: HistoryGatewayFixture.HeldRead) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let wire = try header("target", time: 1)
        await gateway.setCodexHeaders([wire])
        await gateway.holdNextRead(pause)
        let marksStore = ConversationMarksStore(directory: directory)
        #expect(await marksStore.save(ConversationMarksReplica(acknowledged: .init(schemaVersion: 2, revision: 1, readBaseline: 0,
            threads: [wire.id: ThreadMarks(revision: 1, pinName: "Target")]))))
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: store, marksStore: marksStore, defaults: temporary.defaults)
        let recovery = Task { await model.recoverProtectedHeaders(now: .now) }
        await gateway.waitForHeldRead()
        await model.record(ConversationHeader(wire))
        await model.recordThreadName(threadID: wire.id, name: "Newer name")
        await model.recordTurnCompletion(threadID: wire.id, completedAt: 100)
        await gateway.releaseHeldRead()
        await recovery.value
        let restored = await ConversationHeaderStore(hostID: hostID, directory: directory).load()
        let kept = try #require(restored.threads.first { $0.id == wire.id })
        #expect(kept.updatedAt == 1)
        #expect(kept.name == "Newer name")
        #expect(kept.lastTurnCompletedAt == 100)
    }

    @MainActor @Test func missingLiveHeadersAreRecoveredBeforeAnOverfullPassOfUnloadedPins() async throws {
        let hostID = UUID()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let live = try header("z-live", time: 1)
        await gateway.setCodexHeaders([live])
        let marksStore = ConversationMarksStore(directory: directory)
        let marks = ConversationMarks(schemaVersion: 2, revision: 1, readBaseline: 0,
            threads: Dictionary(uniqueKeysWithValues: (0..<40).map { ("pin-\($0)", ThreadMarks(revision: 1, pinName: "Pin \($0)")) }))
        #expect(await marksStore.save(ConversationMarksReplica(acknowledged: marks)))
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: ConversationHeaderStore(hostID: hostID, directory: directory),
            marksStore: marksStore, defaults: temporary.defaults)
        _ = model.setProtectedThreadIDs([live.id])
        await model.recoverProtectedHeaders(now: Date(timeIntervalSince1970: 1_000))
        #expect(await gateway.headerReads.first == live.id)
        #expect(await gateway.headerReads.count == 32)
        #expect(model.header(id: live.id) != nil)
        #expect(model.unloadedPinnedThreads.count == 40)
    }

    @MainActor @Test func replacingRecentCoverageLetsTheSameExhaustedQueryRediscoverAnEvictedMatch() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        var headers = try (0..<1_100).map { try header("claude_\($0)", time: 2_000 - $0) }
        headers[1_099].name = "RareMatch"
        await gateway.setClaudeHeaders(headers)
        await gateway.setCodexHeaders([])
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        await store.save(snapshot: .init(threads: headers.map(ConversationHeader.init), lastSuccessfulRefreshAt: nil, revision: 1))
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: store,
            marksStore: ConversationMarksStore(directory: directory), defaults: temporary.defaults)
        for _ in 0..<10 {
            await model.loadOlder(query: "RareMatch", including: { $0.displayTitle == "RareMatch" })
        }
        #expect(model.header(id: headers[1_099].id) != nil)
        #expect(!model.canLoadOlder(query: "RareMatch"))
        let newer = try (0..<400).map { try header("claude_new-\($0)", time: 3_000 - $0) }
        await gateway.setClaudeHeaders(newer + headers)
        await model.manualRefresh()
        #expect(model.header(id: headers[1_099].id) == nil)
        #expect(model.hasDiscardedHeaders)
        try #require(model.canLoadOlder(query: "RareMatch"))
        let before = await gateway.claudeCursors.count
        for _ in 0..<12 {
            await model.loadOlder(query: "RareMatch", including: { $0.displayTitle == "RareMatch" })
        }
        let cursors = await gateway.claudeCursors
        try #require(cursors.count > before)
        #expect(cursors[before] == nil)
        #expect(model.header(id: headers[1_099].id) != nil)
        #expect(!model.canLoadOlder(query: "RareMatch"))
    }

    @MainActor @Test func aCompleteRecentReadClearsDiscardedCoverageAndPersistsThatChange() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let recent = try header("recent", time: 2_000)
        await gateway.setCodexHeaders([recent])
        await gateway.setCodexCompletionAvailable()
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        await store.save(snapshot: .init(threads: try (0..<1_100).map { ConversationHeader(try header("old-\($0)", time: $0)) },
                         lastSuccessfulRefreshAt: nil, revision: 2))
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: store, marksStore: ConversationMarksStore(directory: directory),
            defaults: temporary.defaults)
        _ = await model.knownThread(id: "old-0")
        #expect(model.hasDiscardedHeaders)
        await model.refresh()
        #expect(model.threads.map(\.id) == [recent.id])
        #expect(!model.hasDiscardedHeaders)
        #expect(!model.canLoadOlder(query: ""))
        let loaded = await ConversationHeaderStore(hostID: hostID, directory: directory).load()
        #expect(!loaded.hasDiscardedHeaders)
        #expect(loaded.threads.map(\.id) == [recent.id])
    }

    @MainActor @Test func neitherBrowsingNorPinRecoveryEvictsPinsThatFillTheWindow() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let pins = try (0..<1_025).map { try header("pin-\($0)", time: 1_000 + $0) }
        let browsed = try header("browsed", time: 1)
        await gateway.setCodexHeaders([browsed])
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        await store.save(snapshot: .init(threads: pins.map(ConversationHeader.init), lastSuccessfulRefreshAt: nil, revision: 3))
        let marksStore = ConversationMarksStore(directory: directory)
        let marks = ConversationMarks(schemaVersion: 2, revision: 1, readBaseline: 0,
            threads: Dictionary(uniqueKeysWithValues: pins.map { ($0.id, ThreadMarks(revision: 1, pinName: $0.id)) }))
        #expect(await marksStore.save(ConversationMarksReplica(acknowledged: marks)))
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: store, marksStore: marksStore, defaults: temporary.defaults)
        await model.loadOlder(query: "", including: { _ in true })
        #expect(model.header(id: browsed.id) == nil)
        #expect(model.hasDiscardedHeaders)
        #expect(Array(model.unloadedPinnedThreads.keys) == [pins[0].id])
        await gateway.setCodexHeaders(pins)
        await model.recoverProtectedHeaders(now: Date(timeIntervalSince1970: 1_000))
        #expect(model.threads.count == ConversationHeaderRetention.countLimit)
        #expect(Array(model.unloadedPinnedThreads.keys) == [pins[0].id])
        #expect(await gateway.headerReads.count == 1)
    }

    @MainActor @Test func unavailablePinnedHeadersBackOffAndNeverAdoptAnotherIdentity() async throws {
        let hostID = UUID()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let marksStore = ConversationMarksStore(directory: directory)
        let marks = ConversationMarks(schemaVersion: 2, revision: 1, readBaseline: 0,
                                      threads: ["missing": ThreadMarks(revision: 1, pinName: "Unloaded pin")])
        #expect(await marksStore.save(ConversationMarksReplica(acknowledged: marks)))
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: ConversationHeaderStore(hostID: hostID, directory: directory),
            marksStore: marksStore, defaults: temporary.defaults)
        let date = Date(timeIntervalSince1970: 1_000)
        for offset in [0, 30, 90, 210, 450, 930, 1_530] {
            await model.recoverProtectedHeaders(now: date.addingTimeInterval(TimeInterval(offset)))
            let count = await gateway.headerReads.count
            await model.recoverProtectedHeaders(now: date.addingTimeInterval(TimeInterval(offset + 29)))
            #expect(await gateway.headerReads.count == count)
            #expect(model.threads.isEmpty)
            #expect(model.unloadedPinnedThreads == ["missing": "Unloaded pin"])
        }
        #expect(await gateway.headerReads == Array(repeating: "missing", count: 7))
        await gateway.setCodexHeaders(try [header("missing", time: 1)])
        await model.recoverProtectedHeaders(now: date.addingTimeInterval(2_130))
        #expect(model.header(id: "missing") != nil)
        #expect(model.unloadedPinnedThreads.isEmpty)
        #expect(await gateway.headerReads.count == 8)
    }

    @MainActor @Test func boundedHeaderWindowReloadsPinsAndLiveIDsAndSearchFindsAnEvictedOlderMatch() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        var headers = try (0..<1_500).map { try header("claude_\($0)", time: 2_000 - $0) }
        headers[1_499].name = "RareMatch old conversation"
        await gateway.setClaudeHeaders(headers)
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        await store.save(snapshot: .init(threads: headers.map(ConversationHeader.init), lastSuccessfulRefreshAt: nil, revision: 4))
        let marksStore = ConversationMarksStore(directory: directory)
        let pinID = headers[1_498].id
        let liveID = headers[1_497].id
        let marks = ConversationMarks(schemaVersion: 2, revision: 1, readBaseline: 0,
                                      threads: [pinID: ThreadMarks(revision: 1, pinName: "Kept pin")])
        #expect(await marksStore.save(ConversationMarksReplica(acknowledged: marks)))
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: store, marksStore: marksStore, defaults: temporary.defaults)
        _ = model.setProtectedThreadIDs([liveID])
        await model.bootstrap()
        #expect(model.threads.count == ConversationHeaderRetention.countLimit)
        #expect(model.hasDiscardedHeaders)
        #expect(model.header(id: pinID) != nil)
        #expect(model.header(id: liveID) != nil)
        #expect(model.unloadedPinnedThreads.isEmpty)
        #expect(model.header(id: headers[1_499].id) == nil)
        #expect(model.continuation.claude == .next("60"))
        for _ in 0..<12 {
            await model.loadOlder(query: "rarematch", including: { $0.displayTitle.localizedStandardContains("rarematch") })
            #expect(model.threads.count <= ConversationHeaderRetention.countLimit)
        }
        #expect(model.header(id: headers[1_499].id)?.name == "RareMatch old conversation")
        #expect(model.header(id: pinID) != nil)
        #expect(model.header(id: liveID) != nil)
        #expect(!model.canLoadOlder(query: "rarematch"))
        #expect(model.canLoadOlder(query: ""))
        #expect(model.continuation.claude == .next("60"))
        #expect(await gateway.pageReads == 0)
        let reloaded = await ConversationHeaderStore(hostID: hostID, directory: directory).load()
        #expect(reloaded.hasDiscardedHeaders)
        #expect(reloaded.threads.count <= ConversationHeaderRetention.countLimit)
        #expect(reloaded.threads.first { $0.id == pinID } != nil)
    }

    @Test(arguments: [false, true])
    func onlyTypedOversizeFailuresReduceHistoryPageSize(_ typed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        await gateway.rejectFirstItemPage(typed: typed)
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        if typed {
            _ = try await service.openTail(header: gateway.header, base: nil)
            #expect(await gateway.itemPageLimits == [50, 25])
        } else {
            do {
                _ = try await service.openTail(header: gateway.header, base: nil)
                Issue.record("An unrelated -32003 error was retried")
            } catch GatewayClient.ClientError.serverError(_, let code) {
                #expect(code == -32003)
            }
            #expect(await gateway.itemPageLimits == [50])
            _ = try await service.openTail(header: gateway.header, base: nil, priority: .reconciliation)
            #expect(await gateway.itemPageLimits == [50, 50])
        }
    }

    @Test func aCapacityDisconnectIsNotRepeatedByBackgroundReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        await gateway.failItemPagesWithCapacity()
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        await #expect(throws: GatewayClient.ClientError.self) {
            _ = try await service.openTail(header: gateway.header, base: nil)
        }
        await #expect(throws: GatewayClient.ClientError.self) {
            _ = try await service.openTail(header: gateway.header, base: nil, priority: .reconciliation)
        }
        #expect(await gateway.itemPageLimits == [50])
    }

    @Test func theDiskTailKeepsItsAgeAndSurvivesAFailedRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let date = Date(timeIntervalSince1970: 1000)
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory), now: { date })
        let tail = try await service.openTail(header: gateway.header, base: nil)
        let paged = try await service.page(header: gateway.header, window: tail.window, direction: .desc, priority: .foreground)
        #expect(paged.window.items.count == 60)
        await gateway.failPages(true)
        do {
            _ = try await service.refreshTail(threadID: gateway.header.id, base: paged.window, bypassCache: true)
            Issue.record("Expected failed read")
        } catch HistoryGatewayFixture.Failure.offline { }
        let restored = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory), now: { date.addingTimeInterval(600) })
        let cached = try #require(await restored.cachedConversation(header: gateway.header))
        #expect(cached.fetchedAt == date)
        #expect(cached.source == .storedTail)
        #expect(cached.update == nil)
        #expect(cached.window.items.pages.flatMap { $0.elements.map(\.id) } == paged.window.items.pages.flatMap { $0.elements.map(\.id) })
    }

    @Test func anUnchangedReconciliationReusesFreshPages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let tail = try await service.openTail(header: gateway.header, base: nil)
        let before = await gateway.pageReads
        let unchanged = try await service.refreshTail(threadID: gateway.header.id, base: tail.window, bypassCache: false)
        #expect(await gateway.pageReads == before)
        #expect(unchanged.window.items.count == tail.window.items.count)
        _ = try await service.refreshTail(threadID: gateway.header.id, base: tail.window, bypassCache: true)
        #expect(await gateway.pageReads == before + 2)
    }

    @Test func aTailServedFromCachedPagesLeavesTheRememberedTokenUsageUnknown() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let breakdown: [String: Any] = ["totalTokens": 42, "inputTokens": 42, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0]
        let usage = try JSONDecoder().decode(CodexAppServerV2.ThreadTokenUsage.self, from: JSONSerialization.data(
            withJSONObject: ["total": breakdown, "last": breakdown, "modelContextWindow": 400_000]))
        func state(merging snapshot: GatewayHistoryService.ConversationSnapshot) throws -> ConversationState {
            var state = ConversationState(conversationID: UUID(), threadID: gateway.header.id)
            state.merge(snapshot)
            state.recordTokenUsage(turnID: try #require(snapshot.window.turns.last?.id), usage: usage)
            return state
        }

        let read = try await service.openTail(header: gateway.header, base: nil)
        #expect(read.source == .gateway)
        #expect(try state(merging: read).validTokenUsage?.last.totalTokens == 42)
        let before = await gateway.pageReads
        let cached = try await service.openTail(header: gateway.header, base: nil)
        #expect(await gateway.pageReads == before)
        #expect(cached.source == .cachedPages)
        #expect(try state(merging: cached).validTokenUsage == nil)
    }

    @Test func settledOlderPagesSurviveAHeaderChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let tail = try await service.openTail(header: gateway.header, base: nil)
        _ = try await service.page(header: gateway.header, window: tail.window, direction: .desc, priority: .foreground)
        let before = await gateway.pageReads
        let changed = HistoryGatewayFixture.header(id: gateway.header.id, updatedAt: 11)
        let reused = try await service.page(header: changed, window: tail.window, direction: .desc, priority: .foreground)
        #expect(await gateway.pageReads == before)
        #expect(reused.window.items.count == 60)
    }

    @Test func anInvalidCursorResetsTheWindowToTheTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        await gateway.setHistory(Self.workingHistory(turns: 80, ordinals: true))
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let tail = try await service.openTail(header: gateway.header, base: nil)
        let older = try await service.page(header: gateway.header, window: tail.window, direction: .desc, priority: .foreground)
        let stale = try #require(older.window.older)
        await gateway.rejectCursor(stale)
        let reset = try await service.page(header: gateway.header, window: older.window, direction: .desc, priority: .foreground)
        #expect(reset.update?.placement == .reset)
        #expect(reset.window.items.pages.flatMap { $0.elements.map(\.id) } == tail.window.items.pages.flatMap { $0.elements.map(\.id) })

        var state = ConversationState(conversationID: UUID(), threadID: gateway.header.id)
        state.merge(older)
        state.merge(reset)
        #expect(state.window?.items.count == tail.window.items.count)
        #expect(state.window?.newer == nil)
    }

    @Test(arguments: [("fixture", true), ("claude_fixture", false)])
    func pagesWithAndWithoutOrdinalsProjectEveryTurnInOrder(threadID: String, ordinals: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture(threadID: threadID)
        await gateway.setHistory(Self.workingHistory(turns: 60, ordinals: ordinals))
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        var state = ConversationState(conversationID: UUID(), threadID: threadID)
        state.merge(try await service.openTail(header: gateway.header, base: nil))
        #expect(ConversationProjection.project(state).items.first.map(Self.signature) == "edge:history-edge-older")
        var pages = 0
        while let window = state.window, window.older != nil, pages < 10 {
            state.merge(try await service.page(header: gateway.header, window: window, direction: .desc, priority: .foreground))
            pages += 1
        }
        #expect(pages == 2)
        let signatures = ConversationProjection.project(state).items.map(Self.signature)
        let expected = (0..<60).flatMap { index in
            ["user:Q\(index)", "timeline:Ran command", "assistant:A\(index)"]
        }
        #expect(signatures == expected)
    }

    @Test func reconnectSplicesTheObservedTailOntoAPagedWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        await gateway.setHistory(Self.workingHistory(turns: 80, ordinals: true))
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        var window = try await service.openTail(header: gateway.header, base: nil).window
        for _ in 0..<1 { window = try await service.page(header: gateway.header, window: window, direction: .desc, priority: .foreground).window }
        let paged = Set(window.items.pages.flatMap { $0.elements.map(\.id) })
        #expect(paged.count == 150)
        await gateway.appendToNewestTurn(5)
        let checkpoint = CodexAppServerV2.ThreadObservationCheckpoint(turnsBackwardsCursor: nil, itemsBackwardsCursor: "checkpoint",
            activeTurn: nil, historyUnavailable: false, liveItems: [])
        let observation = try await service.observationCheckpoint(header: gateway.header, checkpoint: checkpoint, previous: window)
        #expect(observation.entries.count == 50)
        let update = try #require(observation.update)
        let spliced = window.apply(update)
        #expect(spliced)
        let observed = Set(window.items.pages.flatMap { $0.elements.map(\.id) })
        #expect(paged.isSubset(of: observed))
        #expect(observed.count == 155)
    }

    @Test func pageUpdatesCarryMeasuredStorageCosts() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let tail = try await service.openTail(header: gateway.header, base: nil)
        #expect((tail.update?.items.encodedBytes ?? 0) > 0)
        #expect(tail.update?.metadata.allSatisfy { ($0.page.encodedBytes ?? 0) > 0 } == true)
        let older = try await service.page(header: gateway.header, window: tail.window, direction: .desc, priority: .foreground)
        #expect((older.update?.items.encodedBytes ?? 0) > 0)
    }

    static func workingHistory(turns count: Int, ordinals: Bool) -> HistoryGatewayFixture.History {
        var entries: [CodexAppServerV2.ThreadItemsListResponse.Entry] = []
        for index in 0..<count {
            let items: [CodexAppServerV2.ThreadItem] = [
                .userMessage(id: "u\(index)", content: [.text(text: "Q\(index)", textElements: [])]),
                .commandExecution(id: "c\(index)", command: "swift build", cwd: "/tmp", status: .completed,
                    commandActions: [], aggregatedOutput: nil, exitCode: 0, durationMs: nil),
                .agentMessage(id: "a\(index)", text: "A\(index)"),
            ]
            for item in items {
                entries.append(.init(turnId: "t\(index)", item: item, startedAtOrdinal: ordinals ? Int64(entries.count) : nil, isComplete: true))
            }
        }
        let turns = (0..<count).map {
            CodexAppServerV2.Turn(id: "t\($0)", items: [], startedAt: Int64($0), completedAt: Int64($0 + 1),
                status: .completed, error: nil)
        }
        return .init(entries: entries, turns: turns)
    }

    static func signature(_ item: ChatStreamItem) -> String {
        switch item {
        case .message(let message): "\(message.role == .user ? "user" : "assistant"):\(message.text)"
        case .question(let prompt): "question:\(prompt.itemID)"
        case .timeline(let timeline): "timeline:\(timeline.events.map(\.title).joined(separator: ","))"
        case .historyEdge(let edge): "edge:\(edge.id)"
        case .turnOutcome(let outcome): "outcome:\(outcome.turnID)"
        case .viewedMedia(let media): "viewed-media:\(media.path)"
        case .publishedVisual(let visual): "published-visual:\(visual.publication.reference.digest)"
        case .compaction(let marker): "compaction:\(marker.compaction.itemID ?? marker.id)"
        }
    }

    @Test func sidebarUsesCompletionMetadataWithoutReadingHistory() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        await gateway.setCompletionTime(200)
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let first = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(first.threads.first?.lastTurnCompletedAt == 200)
        #expect(first.threads.first?.updatedAt == 10)
        #expect(first.unavailableCompletionTimes.isEmpty)
        // The same second-precision header can now report a newly completed turn.
        await gateway.setCompletionTime(1000)
        let completed = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(completed.threads.first?.lastTurnCompletedAt == 1000)
        #expect(completed.threads.first?.updatedAt == 10)
        await gateway.setCompletionTime(nil)
        let empty = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(empty.threads.first?.lastTurnCompletedAt == nil)
        #expect(empty.unavailableCompletionTimes.isEmpty)
        await gateway.failPages(true)
        let failed = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(failed.unavailableCompletionTimes == ["fixture"])
        #expect(!failed.failures.isEmpty)
        #expect(await gateway.pageReads == 0)
    }

    @MainActor
    @Test func completionDuringRefreshSurvivesOlderReadsFailuresAndRelaunch() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        var header = gateway.header
        header.lastTurnCompletedAt = 100
        await store.save(snapshot: .init(threads: [header], lastSuccessfulRefreshAt: nil, revision: 5))
        await gateway.setCompletionTime(100)
        await gateway.holdNextSummaryRead()
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory.appending(path: "pages")))
        let model = ConversationList(service: service, marksRemote: gateway, hostID: hostID, threadStore: store,
            marksStore: ConversationMarksStore(directory: directory), defaults: temporary.defaults)
        let refresh = Task { await model.refresh() }
        await gateway.waitForSummaryRead()
        await model.recordTurnCompletion(threadID: header.id, completedAt: 500)
        await gateway.releaseSummaryRead()
        await refresh.value
        #expect(model.threads.first?.lastTurnCompletedAt == 500)

        await model.recordTurnCompletion(threadID: header.id, completedAt: 100)
        await model.record(gateway.header)
        #expect(model.threads.first?.lastTurnCompletedAt == 500)
        await service.invalidateAll()
        await gateway.failPages(true)
        await model.refresh()
        #expect(model.threads.first?.lastTurnCompletedAt == 500)
        #expect(model.errorMessage != nil)
        let restored = await ConversationHeaderStore(hostID: hostID, directory: directory).load()
        #expect(restored.threads.first?.lastTurnCompletedAt == 500)
    }

    @MainActor
    @Test(arguments: ["codex_new", "claude_new"])
    func newChatSurvivesIndexingDelayAndRelaunchThenAcceptsHistoryConfirmation(_ threadID: String) async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        await gateway.setCodexCompletionAvailable()
        let existing = try header("existing", time: 500)
        await gateway.setCodexHeaders([existing])
        let hostID = UUID()
        func launch() -> ConversationList {
            ConversationList(service: GatewayHistoryService(gateway: gateway,
                cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
                hostID: hostID, threadStore: ConversationHeaderStore(hostID: hostID, directory: directory),
                marksStore: ConversationMarksStore(directory: directory), defaults: temporary.defaults)
        }

        let model = launch()
        await model.refresh()
        let created = try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: JSONSerialization.data(withJSONObject: [
            "id": threadID, "preview": "", "modelProvider": threadID.hasPrefix("claude_") ? "claude" : "openai",
            "createdAt": 1_000, "updatedAt": 1_000, "cwd": "/repo", "cliVersion": "test", "source": "cli"
        ]))
        await model.record(ConversationHeader(created))
        for _ in 0..<2 {
            await model.refresh()
            #expect(model.threads.first(where: { $0.id == threadID })?.displayTitle == "(untitled)")
        }

        var relaunched = launch()
        await relaunched.manualRefresh()
        #expect(relaunched.threads.contains { $0.id == threadID })
        var expired = try #require(relaunched.threads.first { $0.id == threadID })
        expired.pendingHistorySince = .distantPast
        await ConversationHeaderStore(hostID: hostID, directory: directory).save(snapshot: .init(threads: [expired, ConversationHeader(existing)], lastSuccessfulRefreshAt: nil, revision: 6))
        relaunched = launch()
        await relaunched.record(ConversationHeader(created))
        await relaunched.refresh()
        #expect(relaunched.threads.contains { $0.id == threadID })
        let confirmed = try header(threadID, time: 1_000)
        if threadID.hasPrefix("claude_") {
            await gateway.setClaudeHeaders([confirmed])
        } else {
            await gateway.setCodexHeaders([confirmed, existing])
        }
        await relaunched.refresh()
        #expect(relaunched.threads.first(where: { $0.id == threadID })?.displayTitle == threadID)

        await gateway.setCodexHeaders([existing])
        await gateway.setClaudeHeaders([])
        await relaunched.refresh()
        #expect(!relaunched.threads.contains { $0.id == threadID })

        await relaunched.record(ConversationHeader(created))
        await relaunched.forget(threadID)
        await relaunched.refresh()
        #expect(!relaunched.threads.contains { $0.id == threadID })
    }

    @MainActor @Test func startupMarksReadKeepsCommandsAdmittedWhileItWasHeld() async throws {
        let hostID = UUID()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let disk = ConversationMarksStore(directory: directory)
        var stored = ConversationMarksReplica(acknowledged: await gateway.marks)
        stored.record(.markAllRead(through: 2_000))
        stored.record(.pin(threadID: "same", name: "Stored"))
        stored.record(.pin(threadID: "other", name: "Retained"))
        #expect(await disk.save(stored))
        await gateway.failMarks(true)
        let held = HeldInitialMarksRead(store: disk)
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: ConversationHeaderStore(hostID: hostID, directory: directory),
            marksStore: held, defaults: temporary.defaults)
        let loading = Task { _ = await model.knownThread(id: "same") }
        await held.waitForRead()
        model.pin(threadID: "same", name: "Newer")
        model.unpin(threadID: "other")
        await held.release()
        await loading.value
        #expect(model.pinnedName(for: "same") == "Newer")
        #expect(model.pinnedName(for: "other") == nil)
        #expect(model.marksReplica.pending.map(\.change) == [
            .markAllRead(through: 2_000), .pin(threadID: "same", name: "Stored"), .pin(threadID: "other", name: "Retained"),
            .pin(threadID: "same", name: "Newer"), .unpin(threadID: "other")])
        #expect(await model.flushMarks())
        guard case let .stored(replica) = await disk.load() else { Issue.record("Missing marks"); return }
        #expect(replica == model.marksReplica)
    }

    @MainActor @Test func retiredHeadersStillLoadStoredMarksBeforeAnAdmittedUpdate() async throws {
        let hostID = UUID()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let disk = ConversationMarksStore(directory: directory)
        var stored = ConversationMarksReplica(acknowledged: await gateway.marks)
        stored.record(.pin(threadID: "same", name: "Old"))
        #expect(await disk.save(stored))
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: ConversationHeaderStore(hostID: hostID, directory: directory),
            marksStore: disk, defaults: temporary.defaults)
        model.pin(threadID: "same", name: "New")
        model.retireHeaderReads()
        await model.syncMarks()
        model.quiesce()
        await model.drain()
        #expect(await model.flushMarks())
        #expect(await gateway.markUpdates == [[.pin(threadID: "same", name: "Old"), .pin(threadID: "same", name: "New")]])
        guard case let .stored(replica) = await disk.load() else { Issue.record("Missing marks"); return }
        #expect(replica.pending.isEmpty)
        #expect(replica.effective.pinName(for: "same") == "New")
    }

    @MainActor @Test func marksFlushReportsFailureAndRetriesTheLatestReplica() async throws {
        let hostID = UUID()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marksDirectory = directory.appending(path: "marks")
        let gateway = HistoryGatewayFixture()
        let marksStore = ConversationMarksStore(directory: marksDirectory)
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: ConversationHeaderStore(hostID: hostID, directory: directory),
            marksStore: marksStore, defaults: temporary.defaults)
        await model.syncMarks()
        #expect(await model.flushMarks())
        try FileManager.default.removeItem(at: marksDirectory)
        try Data([1]).write(to: marksDirectory)
        await gateway.failMarks(true)
        model.pin(threadID: "draft", name: "First")
        model.pin(threadID: "draft", name: "Latest")
        await model.drain()
        #expect(await model.flushMarks() == false)
        try FileManager.default.removeItem(at: marksDirectory)
        #expect(await model.flushMarks())
        guard case let .stored(replica) = await marksStore.load() else { Issue.record("Missing marks"); return }
        #expect(replica.effective.pinName(for: "draft") == "Latest")
        #expect(replica.pending.count == 2)
    }

    @MainActor @Test func quiescingMarksJoinsAdmittedAcknowledgementsAndCanResume() async throws {
        let hostID = UUID()
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let marksStore = ConversationMarksStore(directory: directory)
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
            hostID: hostID, threadStore: ConversationHeaderStore(hostID: hostID, directory: directory),
            marksStore: marksStore, defaults: temporary.defaults)
        await model.syncMarks()
        await gateway.holdNextMarksUpdate()
        model.pin(threadID: "admitted", name: "Keep")
        await gateway.waitForHeldMarksUpdate()
        model.quiesce()
        model.pin(threadID: "blocked", name: "Closed")
        var joined = false
        let (started, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let drain = Task {
            continuation.yield(())
            await model.drain()
            joined = true
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!joined)
        await gateway.releaseHeldMarksUpdate()
        await drain.value
        #expect(joined)
        #expect(await model.flushMarks())
        guard case let .stored(replica) = await marksStore.load() else { Issue.record("Missing marks"); return }
        #expect(replica.pending.isEmpty)
        #expect(replica.effective.pinName(for: "admitted") == "Keep")
        #expect(replica.effective.pinName(for: "blocked") == nil)
        model.resume()
        model.pin(threadID: "reopened", name: "Open")
        await model.drain()
        #expect(await model.flushMarks())
        #expect(model.pinnedName(for: "reopened") == "Open")
    }

    @MainActor
    @Test func offlineMarksSurviveRelaunchAndReachTheGatewayInOrderOnceSynced() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        let header = gateway.header
        await store.save(snapshot: .init(threads: [header], lastSuccessfulRefreshAt: nil, revision: 7))
        ConversationPinStore.scoped(hostID: hostID, defaults: temporary.defaults).save(["other": "Legacy"])
        func launch() -> ConversationList {
            ConversationList(service: GatewayHistoryService(gateway: gateway,
                cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
                hostID: hostID, threadStore: store,
                marksStore: ConversationMarksStore(directory: directory), defaults: temporary.defaults)
        }
        func isUnread(_ model: ConversationList) throws -> Bool { model.marks.isUnread(try #require(model.threads.first)) }

        let offline = launch()
        await offline.recordTurnCompletion(threadID: header.id, completedAt: 1_003)
        #expect(try isUnread(offline) == false)
        await gateway.failMarks(true)
        offline.markSeen(threadID: header.id, completedAt: 1_001)
        offline.pin(threadID: header.id, name: "Keep")
        await offline.syncMarks()
        await offline.flushMarks()
        #expect(offline.pinnedName(for: "other") == "Legacy")
        #expect(await gateway.markUpdates.isEmpty)

        let relaunched = launch()
        _ = await relaunched.knownThread(id: header.id)
        #expect(relaunched.pinnedName(for: header.id) == "Keep")
        await gateway.failMarks(false)
        await relaunched.syncMarks()
        await relaunched.flushMarks()
        #expect(await gateway.markUpdates == [[
            .pin(threadID: "other", name: "Legacy"),
            .markRead(threadID: header.id, through: 1_001),
            .pin(threadID: header.id, name: "Keep"),
        ]])
        #expect(try isUnread(relaunched))
        #expect(ConversationPinStore.scoped(hostID: hostID, defaults: temporary.defaults).load().isEmpty)
        guard case let .stored(replica) = await ConversationMarksStore(directory: directory).load() else {
            Issue.record("expected stored marks"); return
        }
        let remoteMarks = await gateway.marks
        #expect(replica.pending.isEmpty)
        #expect(replica.acknowledged == remoteMarks)
    }

    @MainActor @Test func refreshDiscoversOlderAncestryInBoundedBatchesAndThenStopsClassifying() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        await gateway.setUnknownAncestry(["older-100"])
        let time = RetainedAncestryTime()
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        let older = (0..<1_000).map { HistoryGatewayFixture.header(id: "older-\($0)", updatedAt: 1) }
        await gateway.setCodexHeaders(try [header("fixture", time: 10)] + (0..<1_000).map { try header("older-\($0)", time: 1) })
        await gateway.setCodexCompletionAvailable()
        await store.save(snapshot: .init(threads: older, lastSuccessfulRefreshAt: nil, revision: 8))
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages")), now: { time.now }), marksRemote: gateway,
            hostID: hostID, threadStore: store,
            marksStore: ConversationMarksStore(directory: directory), defaults: temporary.defaults)
        await model.bootstrap()
        #expect(await gateway.classificationRequests.flatMap { $0 }.contains("older-100"))
        #expect(model.threads.first { $0.id == "older-100" }?.isDelegatedAgent == false)
        await gateway.setDelegatedIDs(["older-100"])
        await gateway.setUnknownAncestry([])
        time.advance(31)
        for _ in 0..<7 { await model.refresh() }
        #expect(model.threads.count == older.count)
        #expect(model.header(id: "older-100") == nil)
        #expect(!model.hasDiscardedHeaders)
        let requests = await gateway.classificationRequests
        #expect(requests.count <= 8)
        #expect(requests.first?.contains("fixture") == true)
        #expect(requests.allSatisfy { $0.count <= 200 })
        #expect(Set(requests.flatMap { $0 }).count == older.count + 1)
        await model.refresh()
        #expect(await gateway.classificationRequests == requests)
    }

    @MainActor @Test func ancestryWarningsDoNotBlockSuccessfulHistoryRefreshOrPruning() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        await gateway.failClassification()
        let stale = ConversationHeader(try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: Data(#"{"id":"removed","preview":"Removed","modelProvider":"openai","createdAt":1,"updatedAt":1000,"cwd":"/tmp","cliVersion":"test","source":"cli"}"#.utf8)))
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        await store.save(snapshot: .init(threads: [stale], lastSuccessfulRefreshAt: nil, revision: 9))
        let service = GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages")))
        let result = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(result.failures.isEmpty)
        #expect(!result.agentWarnings.isEmpty)
        let model = ConversationList(service: service, marksRemote: gateway, hostID: hostID, threadStore: store,
            marksStore: ConversationMarksStore(directory: directory), defaults: temporary.defaults)
        await model.bootstrap()
        await model.refresh()
        #expect(!model.threads.contains { $0.id == "removed" })
        #expect(model.errorMessage == nil)
        #expect(await store.load().lastSuccessfulRefreshAt != nil)
    }

    @MainActor @Test func truncatedCodexChildPagesRetainUnseenCachedRootsAcrossProviders() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateway = HistoryGatewayFixture()
        let cached = try header("cached-codex-root", time: 75)
        let children = try (0..<600).map { try header("child-\($0)", time: 999 - $0) }
        await gateway.setCodexHeaders(try [header("codex-root", time: 1000)] + children + [cached])
        await gateway.setCodexPageSizeCap(2)
        await gateway.setClaudeHeaders(try [header("claude-root", time: 70)])
        await gateway.setDelegatedIDs(Set(children.map(\.id)))
        await gateway.setCodexCompletionAvailable()
        let hostID = UUID()
        let store = ConversationHeaderStore(hostID: hostID, directory: directory)
        await store.save(snapshot: .init(threads: [ConversationHeader(cached)], lastSuccessfulRefreshAt: nil, revision: 10))
        let model = ConversationList(service: GatewayHistoryService(gateway: gateway,
            cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway, hostID: hostID,
            threadStore: store, marksStore: ConversationMarksStore(directory: directory), defaults: temporary.defaults)
        await model.bootstrap()
        #expect(model.errorMessage?.contains("Codex history reached its page limit") == true)
        #expect(model.threads.contains { $0.id == cached.id })
        #expect(await store.load().lastSuccessfulRefreshAt == nil)
    }

    @Test func exactlyTwentyExhaustedCodexPagesHaveCompleteCoverage() async throws {
        let gateway = HistoryGatewayFixture()
        let children = try (0..<19).map { try header("child-\($0)", time: 999 - $0) }
        await gateway.setCodexHeaders(try [header("root", time: 1000)] + children)
        await gateway.setCodexPageSizeCap(1)
        await gateway.setDelegatedIDs(Set(children.map(\.id)))
        await gateway.setCodexCompletionAvailable()

        let result = try await GatewayHistoryService(gateway: gateway).fetchRecentThreads(limit: 2, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(result.failures.isEmpty)
        #expect(result.threads.filter { !$0.isDelegatedAgent }.map(\.id) == ["root"])
        #expect(await gateway.listCursors.count == 20)
    }

    @Test func longChildRunStillRefillsThirtyCodexRoots() async throws {
        let gateway = HistoryGatewayFixture()
        let firstRoots = try (0..<29).map { try header("root-\($0)", time: 1000 - $0) }
        let children = try (0..<218).map { try header("child-\($0)", time: 970 - $0) }
        let lastRoot = try header("root-29", time: 750)
        await gateway.setCodexHeaders(firstRoots + children + [lastRoot])
        await gateway.setDelegatedIDs(Set(children.map(\.id)))
        await gateway.setCodexCompletionAvailable()

        let result = try await GatewayHistoryService(gateway: gateway).fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(result.failures.isEmpty)
        #expect(result.threads.filter { !$0.isDelegatedAgent }.count == 30)
        #expect(result.threads.contains { $0.id == lastRoot.id })
    }

    @Test func claudePaginationExhaustsFiveHundredChildrenWithoutInventingMoreCoverage() async throws {
        let gateway = HistoryGatewayFixture()
        let children = try (0..<500).map { index in
            try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: JSONSerialization.data(withJSONObject: [
                "id": "claude_child-\(index)", "preview": "Child", "modelProvider": "claude",
                "createdAt": 1, "updatedAt": 1000 - index, "cwd": "/repo", "cliVersion": "test", "source": "cli"
            ]))
        }
        await gateway.setClaudeHeaders(children)
        await gateway.setDelegatedIDs(Set(children.map(\.id)))
        let result = try await GatewayHistoryService(gateway: gateway).fetchRecentThreads(limit: 2, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(!result.failures.contains { $0.hasPrefix("Claude history") })
        #expect(result.continuation.claude == .end)
        #expect(await gateway.claudeCursors.compactMap { $0 }.last == "450")
    }

    @Test func childOnlyPagesRefillRootHistoryForBothProviders() async throws {
        let gateway = HistoryGatewayFixture()
        await gateway.setCodexHeaders(try [header("child-1", time: 90), header("child-2", time: 80), header("root", time: 70)])
        await gateway.setCodexPageSizeCap(2)
        await gateway.setClaudeHeaders(try [header("claude_child-1", time: 95), header("claude_child-2", time: 85), header("claude_root", time: 75)])
        await gateway.setClaudePageSizeCap(2)
        await gateway.setDelegatedIDs(["child-1", "child-2", "claude_child-1", "claude_child-2"])
        let result = try await GatewayHistoryService(gateway: gateway).fetchRecentThreads(limit: 2, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(Set(result.threads.filter { !$0.isDelegatedAgent }.map(\.id)) == ["root", "claude_root"])
        #expect(result.threads.filter(\.isDelegatedAgent).count == 4)
        #expect(await gateway.listCursors == [nil, "2"])
        #expect(await gateway.claudeCursors == [nil, "2"])
        #expect(await gateway.pageReads == 0)
    }

    @Test func sidebarAcceptsClaudeHeaderAndDoesNotReadItsTranscript() async throws {
        let gateway = HistoryGatewayFixture()
        let data = Data("""
        {"id":"claude_fixture","preview":"Claude","modelProvider":"claude","createdAt":1,
         "updatedAt":900,"lastTurnCompletedAt":150,"cwd":"/repo","cliVersion":"test","source":"appServer"}
        """.utf8)
        await gateway.setClaudeHeaders([try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: data)])
        let service = GatewayHistoryService(gateway: gateway)
        let result = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(result.threads.first(where: { $0.id == "claude_fixture" })?.lastTurnCompletedAt == 150)
        #expect(await gateway.requestedThreadIDs.allSatisfy { !$0.hasPrefix("claude_") })
    }

    @Test func oneProviderFailureKeepsTheOtherProvidersHistoryAndReportsCoverage() async throws {
        let gateway = HistoryGatewayFixture()
        await gateway.failClaudeList()
        let service = GatewayHistoryService(gateway: gateway)
        let result = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(result.threads.map(\.id) == ["fixture"])
        #expect(result.failures.count == 1)
        #expect(result.failures[0].hasPrefix("Claude history:"))
    }

    private func header(_ id: String, time: Int) throws -> CodexAppServerV2.Thread {
        try JSONDecoder().decode(CodexAppServerV2.Thread.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "preview": id, "modelProvider": id.hasPrefix("claude_") ? "claude" : "openai",
            "createdAt": 1, "updatedAt": time, "cwd": "/repo", "cliVersion": "test", "source": "cli"
        ]))
    }
}

private final class RetainedAncestryTime: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0.addTimeInterval(seconds) } }
}

private actor HeldInitialMarksRead: ConversationMarksPersistence {
    let store: ConversationMarksStore
    private var reading: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?

    init(store: ConversationMarksStore) { self.store = store }

    func load() async -> ConversationMarksStore.Loaded {
        let saved = await store.load()
        await withCheckedContinuation { reading = $0; arrived?.resume(); arrived = nil }
        return saved
    }

    func save(_ replica: ConversationMarksReplica) async -> Bool { await store.save(replica) }

    func waitForRead() async {
        if reading == nil { await withCheckedContinuation { arrived = $0 } }
    }

    func release() { reading?.resume(); reading = nil }
}
