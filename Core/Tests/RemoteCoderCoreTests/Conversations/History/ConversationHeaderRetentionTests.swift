import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationHeaderRetentionTests {
    @Test func countBoundKeepsProtectedPinnedAndBrowsedHeadersBeforeTheNewest() throws {
        let headers = try (0..<1_100).map { try ThreadFixture.basic("thread-\($0)", updatedAt: Int64($0)) }
        let kept = ConversationHeaderRetention.retain(headers, prioritizing: [headers[0].id], pinned: [headers[1].id], promoting: [headers[2].id])
        #expect(kept.discarded)
        #expect(kept.threads.count == ConversationHeaderRetention.countLimit)
        let newest = try #require(headers.last)
        #expect(Set(kept.threads.map(\.id)).isSuperset(of: [headers[0].id, headers[1].id, headers[2].id, newest.id]))
        #expect(!kept.threads.contains { $0.id == headers[3].id })
        #expect(kept.threads == ConversationHeaderRetention.retain(Array(headers.reversed()), prioritizing: [headers[0].id], pinned: [headers[1].id], promoting: [headers[2].id]).threads)
    }

    @Test func aFullBrowsedPageNeverEvictsPins() throws {
        let pins = try (0..<8).map { try ThreadFixture.basic("pin-\($0)", updatedAt: Int64($0)) }
        let live = try ThreadFixture.basic("live", updatedAt: 100)
        let browsed = try (0..<1_100).map { try ThreadFixture.basic("browsed-\($0)", updatedAt: Int64(1_000 + $0)) }
        let kept = ConversationHeaderRetention.retain(pins + [live] + browsed, prioritizing: [live.id],
                                                       pinned: Set(pins.map(\.id)), promoting: Set(browsed.map(\.id)))
        #expect(kept.discarded)
        #expect(kept.threads.count == ConversationHeaderRetention.countLimit)
        #expect(Set(pins.map(\.id) + [live.id]).isSubset(of: Set(kept.threads.map(\.id))))
        #expect(kept.threads.filter { $0.id.hasPrefix("browsed-") }.count == ConversationHeaderRetention.countLimit - 9)
    }

    @MainActor @Test func onlyProtectedSubagentsStayAndASavedOneSurvivesTheNextLaunch() async throws {
        let temporary = TemporaryHostStorage()
        let suiteName = "RemoteCoderCoreTests.Retention.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { temporary.cleanUp(); defaults.removePersistentDomain(forName: suiteName) }
        let target = ExecutionTarget(hostID: UUID())
        let directory = temporary.storage.directory(for: .target(hostID: target.hostID))
        let gateway = ProjectReadGateway()
        func launch() -> ConversationList {
            ConversationList(service: GatewayHistoryService(gateway: gateway,
                cache: HistoryPageCache(directory: directory.appending(path: "pages"))), marksRemote: gateway,
                hostID: target.hostID, threadStore: ConversationHeaderStore.scoped(to: target, storage: temporary.storage),
                marksStore: ConversationMarksStore(directory: directory), defaults: defaults)
        }
        let root = try ThreadFixture.basic("root", updatedAt: 1)
        var open = try ThreadFixture.basic("open-child", updatedAt: 2)
        open.agentClassification = .child(ConversationAgentRelation(parentThreadId: root.id, parentAccountId: nil, agentId: "worker"))
        let finished = try ThreadFixture.basic("finished-child", updatedAt: 3, fields: ["parentThreadId": root.id])
        await ConversationHeaderStore.scoped(to: target, storage: temporary.storage)
            .save(snapshot: .init(threads: [finished, open, root], lastSuccessfulRefreshAt: nil, revision: 1))
        let list = launch()
        #expect(await list.knownThread(id: finished.id) == finished)
        #expect(list.setProtectedThreadIDs([open.id]))
        await list.record(root)
        #expect(list.threads.map(\.id) == [open.id, root.id])
        #expect(!list.hasDiscardedHeaders)
        #expect(await launch().knownThread(id: open.id) == open)
    }

    @Test func previewsAreBoundedWhenReadFromTheWireAndFromCaches() throws {
        let long = String(repeating: "🦊", count: 2_000) + " tail"
        let wire = try ThreadFixture.basic("wire", updatedAt: 1, preview: long)
        #expect(wire.preview == String(repeating: "🦊", count: ConversationHeader.previewCharacterLimit))
        var cached = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        cached["preview"] = long
        #expect(try JSONDecoder().decode(ConversationHeader.self, from: JSONSerialization.data(withJSONObject: cached)) == wire)
    }

    @Test func unboundedCurrentFormatFileIsBoundedOnLoadAndDiscardedCoverageSurvivesSaveAndReload() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let headers = try (0..<1_100).map { try ThreadFixture.basic("thread-\($0)", updatedAt: Int64($0)) }
        struct UnboundedEnvelope: Encodable {
            let version = 4
            let updatedAt = Date(timeIntervalSince1970: 100)
            let threads: [ConversationHeader]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(UnboundedEnvelope(threads: headers)).write(to: directory.appending(path: "default.json"))
        let store = ConversationHeaderStore(hostID: nil, directory: directory)
        let loaded = await store.load()
        #expect(loaded.threads.count == ConversationHeaderRetention.countLimit)
        #expect(loaded.hasDiscardedHeaders)
        await store.save(snapshot: .init(threads: loaded.threads, lastSuccessfulRefreshAt: nil, hasDiscardedHeaders: loaded.hasDiscardedHeaders, revision: 1))
        let reloaded = await ConversationHeaderStore(hostID: nil, directory: directory).load()
        #expect(reloaded.hasDiscardedHeaders)
        #expect(reloaded.threads == loaded.threads)
        let file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "default.json"))) as? [String: Any])
        #expect((file["threads"] as? [Any])?.count == ConversationHeaderRetention.countLimit)
    }
}
