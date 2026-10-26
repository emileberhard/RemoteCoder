import Foundation
import Observation
import Synchronization
import Testing
@testable import RemoteCoderCore

@MainActor
struct HistoryRefreshTests {
    @Test func theSafetyReadDeadlineDoesNotMoveWithCheapPolls() {
        let full = Date(timeIntervalSince1970: 1_000)
        #expect(HistoryRefreshTiming.needsFullRead(after: nil, now: full))
        #expect(!HistoryRefreshTiming.needsFullRead(after: full, now: full.addingTimeInterval(299)))
        #expect(HistoryRefreshTiming.needsFullRead(after: full, now: full.addingTimeInterval(300)))
    }

    @Test func lifecycleNotificationsCoalesceAndUnrelatedNotificationsDoNotRefresh() async throws {
        try await withList { list, gateway, _ in
            await list.refresh()
            await gateway.resetRequests()
            for method in ["thread/started", "thread/status/changed"] {
                let params: JSONValue = method == "thread/started"
                    ? .object(["thread": .object(["id": .string("new")])])
                    : .object(["threadId": .string("new"), "status": .object(["type": .string("idle")])])
                let note = CodexGatewayNotification(method: method, params: params,
                    server: ServerNotification.decode(method: method, params: params))
                let event = try #require(GatewayNotificationRouting.route(note))
                for _ in 0..<20 { list.refresh(after: event) }
            }
            try #require(await waitUntil { await gateway.requests == 2 })
            #expect(list.errorMessage == nil)
            for method in ["account/updated", "item/agentMessage/delta", "thread/tokenUsage/updated"] {
                let note = CodexGatewayNotification(method: method, params: .object([:]),
                    server: ServerNotification.decode(method: method, params: .object([:])))
                if let event = GatewayNotificationRouting.route(note) {
                    #expect(!event.requiresHistoryRefresh)
                    list.refresh(after: event)
                }
            }
            try await Task.sleep(for: .milliseconds(350))
            #expect(await gateway.requests == 2)
        }
    }

    @Test func anEventDuringAReadGetsOneTrailingRefreshAndClosingCancelsPendingWork() async throws {
        try await withList { list, gateway, _ in
            await list.refresh()
            await gateway.resetRequests()
            await gateway.holdNextCodexRead()
            list.refresh(after: .threadChanged(threadID: "new", sequence: nil))
            try #require(await waitUntil { await gateway.isHeld })
            for _ in 0..<20 { list.refresh(after: .threadChanged(threadID: "new", sequence: nil)) }
            await gateway.releaseRead()
            try #require(await waitUntil { await gateway.requests == 4 })
            list.refresh(after: .threadChanged(threadID: "cancelled", sequence: nil))
            list.cancelEventRefresh()
            try await Task.sleep(for: .milliseconds(350))
            #expect(await gateway.requests == 4)
        }
    }

    @Test func hiddenChildTimestampNoiseRetainsTheArrayAndFileButVisibleChangesPublishAndPersist() async throws {
        try await withList { list, gateway, file in
            _ = list.setProtectedThreadIDs(["child"])
            await gateway.setCodex([Self.child(updatedAt: 2)])
            await list.refresh()
            let before = try Data(contentsOf: file)
            let fileNumber = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)
            let published = Mutex(false)
            withObservationTracking { _ = list.threads } onChange: { published.withLock { $0 = true } }
            await gateway.setCodex([Self.child(updatedAt: 100)])
            await list.refresh()
            #expect(!published.withLock { $0 })
            #expect(list.threads.first?.updatedAt == 2)
            #expect(try Data(contentsOf: file) == before)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == fileNumber)
            var renamed = Self.child(updatedAt: 101)
            renamed.name = "New child title"
            await gateway.setCodex([renamed])
            await list.refresh()
            #expect(published.withLock { $0 })
            #expect(list.threads.first?.name == "New child title")
            #expect(list.threads.first?.updatedAt == 101)
            #expect(try Data(contentsOf: file) != before)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber != fileNumber)
            let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(envelope["version"] as? Int == 4)
        }
    }

    @Test func rootTimestampAndHiddenChildMeaningRemainAuthoritative() {
        let root = ConversationHeader(CodexAppServerV2.Thread.historyFixture(id: "root", updatedAt: 2))
        let newerRoot = ConversationHeader(CodexAppServerV2.Thread.historyFixture(id: "root", updatedAt: 3))
        #expect(newerRoot.retainingHiddenAgentTimestamp(from: root).updatedAt == 3)
        let child = ConversationHeader(Self.child(updatedAt: 2))
        var completed = ConversationHeader(Self.child(updatedAt: 3))
        completed.lastTurnCompletedAt = 50
        #expect(completed.retainingHiddenAgentTimestamp(from: child).lastTurnCompletedAt == 50)
        var changedAncestry = ConversationHeader(Self.child(updatedAt: 3))
        changedAncestry.nativeParentThreadID = "other-parent"
        #expect(changedAncestry.retainingHiddenAgentTimestamp(from: child).nativeParentThreadID == "other-parent")
    }

    @Test func pollingStopsAtTheFirstUnchangedPageAndFullReadsDiscoverOlderRenames() async throws {
        let gateway = RefreshGateway()
        let service = GatewayHistoryService(gateway: gateway)
        var headers = (0..<120).map { Self.child(id: "child-\($0)", updatedAt: Int64(500 - $0)) }
        headers += (0..<60).map { .historyFixture(id: "root-\($0)", updatedAt: Int64(300 - $0)) }
        await gateway.setCodex(headers)
        let full = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(full.threads.count == 180)
        await gateway.resetRequests()
        let stable = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: full.threads, read: .untilUnchanged)
        #expect(stable.isUnchanged)
        #expect(stable.continuation.codex == .next("1"))
        #expect(await gateway.requests == 2)
        headers[0].name = "Changed first page"
        headers[150].name = "Old external rename"
        await gateway.setCodex(headers)
        await gateway.resetRequests()
        let prefix = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: full.threads, read: .untilUnchanged)
        #expect(!prefix.isUnchanged)
        #expect(prefix.threads.count == 61)
        #expect(prefix.threads.first?.name == "Changed first page")
        #expect(prefix.continuation.codex == .next("61"))
        #expect(await gateway.requests == 3)
        let safety = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: full.threads, read: .full)
        #expect(safety.threads.first { $0.id == "root-30" }?.name == "Old external rename")
        #expect(!safety.continuation.canLoad)
    }

    @Test func aLateReadCannotReplaceTheNewerPageComparisonSnapshot() async throws {
        let gateway = RefreshGateway()
        let service = GatewayHistoryService(gateway: gateway)
        await gateway.setCodex([.historyFixture(id: "root")])
        await gateway.holdNextCodexRead()
        let older = Task { try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full) }
        defer { await gateway.releaseRead(); _ = await older.result }
        try #require(await waitUntil { await gateway.isHeld })
        var renamed = CodexAppServerV2.Thread.historyFixture(id: "root")
        renamed.name = "New title"
        await gateway.setCodex([renamed])
        _ = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        await gateway.releaseRead()
        await #expect(throws: CancellationError.self) { try await older.value }
        let stable = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .untilUnchanged)
        #expect(stable.isUnchanged)
        #expect(stable.threads.first?.name == "New title")
    }

    @Test func anUnchangedPrefixStillAdoptsNewlyResolvedRetainedAncestry() async throws {
        try await withList { list, gateway, file in
            await ConversationHeaderStore(hostID: nil, directory: file.deletingLastPathComponent()).save(snapshot:
                .init(threads: [.historyFixture(id: "old-unknown", updatedAt: 1)], lastSuccessfulRefreshAt: nil, revision: 1))
            _ = list.setProtectedThreadIDs(["old-unknown"])
            await gateway.setCodex([.historyFixture(id: "root", updatedAt: 2)])
            await gateway.setUnknown("old-unknown")
            await list.refresh()
            #expect(list.header(id: "old-unknown")?.agentClassification == .unresolved)
            let before = try Data(contentsOf: file)
            await gateway.resolveChild("old-unknown")
            let completed = list.lastSuccessfulRefreshAt
            list.refresh(after: .threadChanged(threadID: "root", sequence: nil))
            try #require(await waitUntil {
                list.lastSuccessfulRefreshAt != completed && (try? Data(contentsOf: file)) != before
            })
            #expect(list.header(id: "old-unknown")?.agentParentThreadID == "parent")
        }
    }

    @Test func unchangedPollDoesNotMergePublishOrWrite() async throws {
        try await withList { list, gateway, file in
            await gateway.setCodex([.historyFixture(id: "root")])
            await list.refresh()
            let before = try Data(contentsOf: file)
            let fileNumber = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)
            let published = Mutex(false)
            withObservationTracking { _ = list.threads } onChange: { published.withLock { $0 = true } }
            let completed = list.lastSuccessfulRefreshAt
            list.refresh(after: .threadChanged(threadID: "root", sequence: nil))
            try #require(await waitUntil { list.lastSuccessfulRefreshAt != completed })
            #expect(await gateway.requests == 4)
            #expect(!published.withLock { $0 })
            #expect(try Data(contentsOf: file) == before)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == fileNumber)
        }
    }

    private static func child(id: String = "child", updatedAt: Int64) -> CodexAppServerV2.Thread {
        var thread = CodexAppServerV2.Thread.historyFixture(id: id, updatedAt: updatedAt)
        thread.parentThreadId = "parent"
        return thread
    }

    private func withList(_ body: (ConversationList, RefreshGateway, URL) async throws -> Void) async throws {
        let temporary = TemporaryHostStorage()
        let suiteName = "HistoryRefreshTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { temporary.cleanUp(); defaults.removePersistentDomain(forName: suiteName) }
        let directory = temporary.storage.root.appending(path: "headers")
        let gateway = RefreshGateway()
        let list = ConversationList(service: GatewayHistoryService(gateway: gateway, now: { gateway.now }), marksRemote: gateway,
            hostID: UUID(), threadStore: ConversationHeaderStore(hostID: nil, directory: directory),
            marksStore: ConversationMarksStore(directory: temporary.storage.root), defaults: defaults)
        defer { list.retireHeaderReads(); await list.finishHeaderRetirement() }
        try await body(list, gateway, directory.appending(path: "default.json"))
    }
}

private actor RefreshGateway: CodexHistoryGateway, ConversationMarksRemote {
    enum Failure: Error { case unexpectedRead }
    let historyHostID = "refresh-fixture"
    private var codex: [CodexAppServerV2.Thread] = []
    private let time = Mutex(Date.now)
    private var unknown: Set<String> = []
    private var children: Set<String> = []
    nonisolated var now: Date { time.withLock { $0 } }
    func setUnknown(_ id: String) { unknown.insert(id) }
    func resolveChild(_ id: String) {
        unknown.remove(id)
        children.insert(id)
        time.withLock { $0 = $0.addingTimeInterval(601) }
    }
    private(set) var requests = 0
    private var holdsNext = false
    private var held: CheckedContinuation<Void, Never>?
    var isHeld: Bool { held != nil }

    func setCodex(_ threads: [CodexAppServerV2.Thread]) { codex = threads }
    func resetRequests() { requests = 0 }
    func holdNextCodexRead() { holdsNext = true }
    func releaseRead() { held?.resume(); held = nil }
    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) async -> CodexAppServerV2.ThreadListResponse {
        requests += 1
        let threads = codex
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { held = $0 }
        }
        let start = cursor.flatMap(Int.init) ?? 0
        let end = min(threads.count, start + limit)
        let page = Array(threads[start..<end])
        return .init(data: page, nextCursor: end < threads.count ? String(end) : nil,
            completionTimes: Dictionary(uniqueKeysWithValues: page.map { ($0.id, Optional<Int64>.some(1)) }))
    }
    func listClaudeThreads(limit: Int, cursor: String?) -> CodexAppServerV2.ThreadListResponse {
        requests += 1
        return .init(data: [], nextCursor: nil)
    }
    func readThread(threadID: String, includeTurns: Bool) throws -> CodexAppServerV2.ThreadReadResponse { throw Failure.unexpectedRead }
    func historyPageData(method: String, params: JSONValue) throws -> Data {
        guard method == "conversation/agents/classify" else { throw Failure.unexpectedRead }
        let ids = params.objectValue?["threadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let relations = Dictionary(uniqueKeysWithValues: ids.filter { children.contains($0) }.map {
            ($0, ConversationAgentRelation(parentThreadId: "parent", parentAccountId: nil, agentId: "launcher:" + $0))
        })
        return try JSONSerialization.data(withJSONObject: ["result": [
            "relations": try JSONSerialization.jsonObject(with: JSONEncoder().encode(relations)),
            "warnings": [], "knownRoots": ids.filter { !unknown.contains($0) && !children.contains($0) }]])
    }
    func resolveProjects(directories: [String]) -> [ProjectIdentity] { [] }
    func readConversationMarks() throws -> ConversationMarks { throw Failure.unexpectedRead }
    func updateConversationMarks(_ changes: [ConversationMarkChange]) throws -> ConversationMarks? { throw Failure.unexpectedRead }
}
