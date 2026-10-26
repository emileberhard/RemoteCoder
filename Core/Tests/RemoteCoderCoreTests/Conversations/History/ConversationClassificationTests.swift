import Foundation
import Synchronization
import Testing
@testable import RemoteCoderCore

struct ConversationClassificationTests {
    @Test(arguments: [false, true])
    func freshHeadersKeepRetainedNativeAncestryWithoutLauncherClassification(_ onlySpawnEvidence: Bool) async throws {
        var fields: [String: Any] = ["id": "native", "preview": "Native child", "modelProvider": "openai",
            "createdAt": 1, "updatedAt": 2, "cwd": "/repo", "cliVersion": "test", "source": "cli"]
        if onlySpawnEvidence {
            fields["source"] = ["subAgent": ["thread_spawn": [:]]] as [String: Any]
        } else {
            fields["parentThreadId"] = "native-parent"
        }
        let retained = ConversationHeader(try JSONDecoder().decode(CodexAppServerV2.Thread.self,
            from: JSONSerialization.data(withJSONObject: fields)))
        let gateway = ClassificationGateway()
        await gateway.setHeaders([.historyFixture(id: retained.id)])
        let service = GatewayHistoryService(gateway: gateway)
        let fresh = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [retained], read: .full)
        #expect(fresh.threads.first?.isNativeAgent == true)
        #expect(fresh.threads.first?.nativeParentThreadID == retained.nativeParentThreadID)
        #expect(fresh.threads.first?.spawnedAsSubAgent == retained.spawnedAsSubAgent)
        #expect(await gateway.classified.isEmpty)
    }

    @Test func bothProvidersContinueWithoutSkippingTheRestOfTheirFirstPages() async throws {
        let gateway = ClassificationGateway()
        let codex = (0..<701).map { CodexAppServerV2.Thread.historyFixture(id: "codex-\($0)", updatedAt: Int64(2_000 - $0)) }
        let claude = (0..<701).map { CodexAppServerV2.Thread.historyFixture(id: "claude_\($0)", updatedAt: Int64(3_000 - $0)) }
        await gateway.setHeaders(codex)
        await gateway.setClaudeHeaders(claude)
        let service = GatewayHistoryService(gateway: gateway)
        let page = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(page.threads.count == 120)
        #expect(page.continuation == .init(codex: .next("60"), claude: .next("60")))
        var seen = Set(page.threads.map(\.id))
        var retained = page.threads
        var positions = page.continuation
        var pages = 1
        for index in 0..<8 {
            let provider: AgentProvider = index.isMultiple(of: 2) ? .codex : .claude
            let position = provider == .codex ? positions.codex : positions.claude
            #expect(position.canLoad)
            let page = try await service.fetchOlderPage(provider: provider, position: position, knownHeaders: retained)
            #expect(page.unavailable.isEmpty)
            #expect(seen.isDisjoint(with: page.threads.map(\.id)))
            seen.formUnion(page.threads.map(\.id))
            retained = ConversationHeaderRetention.retain(ConversationHeaderStore.merging(current: retained, fetched: page.threads),
                prioritizing: [], pinned: [], promoting: Set(page.threads.map(\.id))).threads
            #expect(retained.count <= ConversationHeaderRetention.countLimit)
            if provider == .codex { positions.codex = page.position } else { positions.claude = page.position }
            pages += 1
        }
        #expect(!positions.canLoad)
        #expect(seen == Set((codex + claude).map(\.id)))
        #expect(pages == 9)
        let done = try await service.fetchOlderPage(provider: .codex, position: positions.codex, knownHeaders: retained)
        #expect(done.threads.isEmpty)
        #expect(await gateway.listRequests.count == 10)
    }

    @Test func persistedDefinitiveHeadersSurviveCacheEvictionAndOnlyUnknownRowsRotate() async throws {
        let gateway = ClassificationGateway()
        await gateway.setChild("child")
        await gateway.setUnknown("pending")
        let service = GatewayHistoryService(gateway: gateway)
        let initial = await service.classifyAgents([.historyFixture(id: "root"), .historyFixture(id: "child"), .historyFixture(id: "pending")])
        #expect(initial.threads.map(\.agentClassification) == [.root, .child(.init(parentThreadId: "parent",
            parentAccountId: nil, agentId: "launcher:child")), .unresolved])
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let store = ConversationHeaderStore(hostID: nil, storage: temporary.storage)
        await store.save(snapshot: .init(threads: initial.threads, lastSuccessfulRefreshAt: nil, revision: 1))
        let restored = await ConversationHeaderStore(hostID: nil, storage: temporary.storage).load().threads
        _ = await service.classifyAgents((0..<4_200).map { .historyFixture(id: "churn-\($0)") })
        let before = await gateway.classified.count
        let retried = await service.classifyRetainedAgents(restored)
        #expect(await gateway.classified.count == before + 1)
        #expect(await gateway.classified.last == ["pending"])
        #expect(retried.threads.map(\.agentClassification) == [.unresolved])
        let merged = ConversationHeaderStore.merging(current: restored, fetched: [.historyFixture(id: "root", updatedAt: 10)])
        #expect(merged.first { $0.id == "root" }?.agentClassification == .root)
        #expect(await service.classifyRetainedAgents(merged.filter { $0.id != "pending" }).threads.isEmpty)
        #expect(await gateway.classified.count == before + 1)
        #expect(!retried.warnings.isEmpty)
        await gateway.setHeaders([.historyFixture(id: "root"), .historyFixture(id: "child")])
        let fresh = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: restored, read: .full)
        #expect(fresh.threads.first { $0.id == "root" }?.agentClassification == .root)
        #expect(fresh.threads.first { $0.id == "child" }?.agentParentThreadID == "parent")
        #expect(await gateway.classified.count == before + 1)
    }

    @Test func unchangedHeadersReuseAncestryAndNewHeadersAloneAreClassified() async throws {
        let gateway = ClassificationGateway()
        var native = CodexAppServerV2.Thread.historyFixture(id: "native")
        native.parentThreadId = "native-parent"
        await gateway.setHeaders([.historyFixture(id: "root"), .historyFixture(id: "child"), native])
        await gateway.setChild("child")
        let service = GatewayHistoryService(gateway: gateway)
        let first = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(first.threads.first { $0.id == "child" }?.agentParentThreadID == "parent")
        #expect(first.threads.first { $0.id == "native" }?.agentParentThreadID == "native-parent")
        let second = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(second.threads == first.threads)
        #expect(await gateway.classified == [["root", "child"]])
        await gateway.setHeaders([.historyFixture(id: "new"), .historyFixture(id: "root"), .historyFixture(id: "child"), native])
        let third = try await service.fetchRecentThreads(limit: 30, useStateDBOnly: true, knownHeaders: [], read: .full)
        #expect(Set(third.threads.map(\.id)) == ["new", "root", "child", "native"])
        #expect(third.threads.first { $0.id == "child" }?.agentParentThreadID == "parent")
        #expect(await gateway.classified == [["root", "child"], ["new"]])
    }

    @Test func lateUnknownResponseCannotReplaceNewerDefinitiveAncestry() async {
        let gateway = ClassificationGateway()
        await gateway.setUnknown("pending")
        await gateway.holdNextClassification()
        let service = GatewayHistoryService(gateway: gateway)
        let header = ConversationHeader.historyFixture(id: "pending")
        let older = Task { await service.classifyAgents([header]) }
        await gateway.waitForHeldClassification()
        await gateway.setChild("pending")
        let newer = await service.classifyAgents([header])
        #expect(newer.threads[0].agentParentThreadID == "parent")
        await gateway.releaseClassification()
        let late = await older.value
        #expect(late.threads[0].agentParentThreadID == "parent")
        let retained = await service.classifyAgents([header])
        #expect(retained.threads[0].agentParentThreadID == "parent")
        #expect(await gateway.classified.count == 2)
    }

    @Test func unknownAncestryRetriesAfterItsDeadlineAndImmediatelyAfterHeaderChange() async throws {
        let time = ClassificationTime()
        let gateway = ClassificationGateway()
        await gateway.setUnknown("pending")
        let service = GatewayHistoryService(gateway: gateway, now: { time.now })
        let pending = ConversationHeader.historyFixture(id: "pending")
        let first = await service.classifyAgents([pending])
        #expect(!first.threads[0].isDelegatedAgent)
        #expect(!first.warnings.isEmpty)
        await gateway.setChild("pending")
        let unchanged = await service.classifyAgents([pending])
        #expect(!unchanged.threads[0].isDelegatedAgent)
        #expect(await gateway.classified.count == 1)
        time.advance(31)
        let resolved = await service.classifyAgents([pending])
        #expect(resolved.threads[0].agentParentThreadID == "parent")
        #expect(await gateway.classified.count == 2)
        await gateway.setUnknown("changed")
        let changed = ConversationHeader.historyFixture(id: "changed")
        _ = await service.classifyAgents([changed])
        await gateway.setChild("changed")
        let updated = await service.classifyAgents([.historyFixture(id: "changed", updatedAt: 3)])
        #expect(updated.threads[0].agentParentThreadID == "parent")
        #expect(await gateway.classified.count == 4)
    }

    @Test func classificationDoesNotSilentlyStopAfterTwoThousandRowsAndEvictsOldEvidence() async {
        let gateway = ClassificationGateway()
        let service = GatewayHistoryService(gateway: gateway)
        let rows = (0..<4_200).map { ConversationHeader.historyFixture(id: "row-\($0)") }
        let result = await service.classifyAgents(rows)
        #expect(result.warnings.isEmpty)
        #expect(await gateway.classified.flatMap { $0 }.count == rows.count)
        #expect(await gateway.classified.allSatisfy { $0.count <= 200 })
        _ = await service.classifyAgents([rows[0], rows[4_199]])
        #expect(await gateway.classified.last == ["row-0"])
    }

    @Test func missingRootCoverageRemainsRetryableAndHostInvalidationDropsCachedEvidence() async {
        let time = ClassificationTime()
        let gateway = ClassificationGateway()
        await gateway.omitRootCoverage()
        let service = GatewayHistoryService(gateway: gateway, now: { time.now })
        let root = ConversationHeader.historyFixture(id: "root")
        _ = await service.classifyAgents([root])
        time.advance(31)
        _ = await service.classifyAgents([root])
        #expect(await gateway.classified.count == 2)
        await service.invalidateAll()
        _ = await service.classifyAgents([root])
        #expect(await gateway.classified.count == 3)
    }

    @Test func retainedUnknownsBackOffPerEntryAndChangedHeadersRetryImmediately() async {
        let time = ClassificationTime()
        let gateway = ClassificationGateway()
        await gateway.setUnknown("permanent")
        let service = GatewayHistoryService(gateway: gateway, now: { time.now })
        let header = ConversationHeader.historyFixture(id: "permanent")
        let first = await service.classifyRetainedAgents([header])
        #expect(!first.threads[0].isDelegatedAgent)
        #expect(!first.warnings.isEmpty)
        for _ in 0..<5 { _ = await service.classifyRetainedAgents([header]) }
        #expect(await gateway.classified.count == 1)
        time.advance(31)
        _ = await service.classifyRetainedAgents([header])
        time.advance(31)
        #expect(await service.classifyRetainedAgents([header]).threads.isEmpty)
        time.advance(30)
        _ = await service.classifyRetainedAgents([header])
        #expect(await gateway.classified.count == 3)
        let changed = ConversationHeader.historyFixture(id: header.id, updatedAt: header.updatedAt + 1)
        _ = await service.classifyRetainedAgents([changed])
        #expect(await gateway.classified.count == 4)
        for interval in [31, 61, 121, 241, 481, 601] {
            time.advance(TimeInterval(interval))
            _ = await service.classifyRetainedAgents([changed])
        }
        #expect(await gateway.classified.count == 10)
        time.advance(599)
        #expect(await service.classifyRetainedAgents([changed]).threads.isEmpty)
        await gateway.setChild(header.id)
        time.advance(2)
        let resolved = await service.classifyRetainedAgents([changed])
        #expect(resolved.threads[0].agentParentThreadID == "parent")
        time.advance(3_600)
        #expect(await service.classifyRetainedAgents(resolved.threads).threads.isEmpty)
        #expect(await gateway.classified.count == 11)
    }

    @Test func retainedHeaderUsesAlreadyKnownChildEvidenceWithoutAnotherRPC() async {
        let gateway = ClassificationGateway()
        await gateway.setChild("child")
        let service = GatewayHistoryService(gateway: gateway)
        let header = ConversationHeader.historyFixture(id: "child")
        _ = await service.classifyAgents([header])
        let retained = await service.classifyRetainedAgents([header])
        #expect(retained.threads.first?.agentParentThreadID == "parent")
        #expect(await gateway.classified.count == 1)
    }

    @Test func retainedUnknownHeaderImportsCachedRootEvidenceWithoutAnotherRPC() async {
        let gateway = ClassificationGateway()
        let service = GatewayHistoryService(gateway: gateway)
        let header = ConversationHeader.historyFixture(id: "root")
        _ = await service.classifyAgents([header])
        let retained = await service.classifyRetainedAgents([header])
        #expect(retained.threads.first?.agentClassification == .root)
        #expect(await gateway.classified.count == 1)
        #expect(await service.classifyRetainedAgents(retained.threads).threads.isEmpty)
    }
}

private final class ClassificationTime: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0.addTimeInterval(seconds) } }
}

private actor ClassificationGateway: CodexHistoryGateway {
    let historyHostID = "classification"
    private var headers: [CodexAppServerV2.Thread] = []
    private var claudeHeaders: [CodexAppServerV2.Thread] = []
    private(set) var listRequests: [String?] = []
    private var children: Set<String> = []
    private var unknown: Set<String> = []
    private var rootCoverage = true
    private var holdsNextClassification = false
    private var heldClassification: (Data, CheckedContinuation<Data, Never>)?
    private var arrival: CheckedContinuation<Void, Never>?
    private(set) var classified: [[String]] = []

    func setHeaders(_ headers: [CodexAppServerV2.Thread]) { self.headers = headers }
    func setClaudeHeaders(_ headers: [CodexAppServerV2.Thread]) { self.claudeHeaders = headers }
    func setChild(_ id: String) { children.insert(id); unknown.remove(id) }
    func setUnknown(_ id: String) { unknown.insert(id); children.remove(id) }
    func omitRootCoverage() { rootCoverage = false }
    func holdNextClassification() { holdsNextClassification = true }
    func waitForHeldClassification() async {
        if heldClassification == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func releaseClassification() {
        if let heldClassification { heldClassification.1.resume(returning: heldClassification.0) }
        heldClassification = nil
    }

    func listThreads(limit: Int, cursor: String?, useStateDBOnly: Bool) -> CodexAppServerV2.ThreadListResponse {
        listRequests.append(cursor)
        let start = cursor.flatMap(Int.init) ?? 0
        let page = Array(headers.dropFirst(start).prefix(limit))
        let next = start + page.count
        return .init(data: page, nextCursor: next < headers.count ? String(next) : nil,
            completionTimes: Dictionary(uniqueKeysWithValues: page.map { ($0.id, Optional<Int64>.some(1)) }))
    }
    func listClaudeThreads(limit: Int, cursor: String?) -> CodexAppServerV2.ThreadListResponse {
        listRequests.append(cursor)
        let start = cursor.flatMap(Int.init) ?? 0
        let page = Array(claudeHeaders.dropFirst(start).prefix(limit))
        let next = start + page.count
        return .init(data: page, nextCursor: next < claudeHeaders.count ? String(next) : nil)
    }
    func readThread(threadID: String, includeTurns: Bool) -> CodexAppServerV2.ThreadReadResponse { .init(thread: .historyFixture(id: threadID)) }
    func historyPageData(method: String, params: JSONValue) async throws -> Data {
        guard method == "conversation/agents/classify" else { throw GatewayClient.ClientError.invalidMessage }
        let ids = params.objectValue?["threadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        classified.append(ids)
        let relations = Dictionary(uniqueKeysWithValues: ids.filter { children.contains($0) }.map {
            ($0, ["parentThreadId": "parent", "agentId": "launcher:\($0)"])
        })
        var result: [String: Any] = ["relations": relations, "warnings": ids.contains { unknown.contains($0) } ? ["identityPending"] : []]
        if rootCoverage { result["knownRoots"] = ids.filter { !children.contains($0) && !unknown.contains($0) } }
        let data = try JSONSerialization.data(withJSONObject: ["result": result])
        if holdsNextClassification {
            holdsNextClassification = false
            return await withCheckedContinuation {
                heldClassification = (data, $0)
                arrival?.resume()
                arrival = nil
            }
        }
        return data
    }
}
