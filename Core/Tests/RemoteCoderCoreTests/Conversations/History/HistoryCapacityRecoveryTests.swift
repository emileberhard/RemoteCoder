import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct HistoryCapacityRecoveryTests {
    @Test func foregroundJoiningPrefetchSharesCapacityRecovery() async throws {
        let fixture = try DeviceToolSocketFixture(declarationReply: .accepted)
        let emptyPage = JSONValue.object(["data": .array([]), "nextCursor": .null, "backwardsCursor": .null])
        await fixture.holdRequests("thread/items/list")
        let port = try await fixture.start()
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:\(port)")),
            authToken: "fixture", hostLabel: "Fixture"), routes: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = GatewayHistoryService(gateway: gateway, cache: HistoryPageCache(directory: directory))
        let header = ConversationHeader.historyFixture()
        var window = HistoryWindow()
        window.apply(.init(items: .init(elements: [], older: "older", newer: nil, fetchedAt: .now), placement: .tail, metadata: []))
        let base = window
        let prefetch = Task { try await service.page(header: header, window: base, direction: .desc, priority: .prefetch) }
        defer { prefetch.cancel() }
        do {
            for await request in fixture.requests where request.method == "thread/items/list" { break }
            let foreground = Task { try await service.page(header: header, window: base, direction: .desc, priority: .foreground) }
            defer { foreground.cancel() }
            try #require(await waitUntil { await service.diagnosticCounters().waiters == 2 })
            try await fixture.refuseHeldRequestsForCapacity()
            let retried = await waitUntil {
                await fixture.recordedRequests.filter { $0.method == "thread/items/list" }.count == 2
            }
            #expect(retried)
            if retried { try await fixture.releaseRequests(result: emptyPage) }
            #expect(try await foreground.value.window.items.pages.flatMap(\.elements).isEmpty)
            #expect(try await prefetch.value.window.items.pages.flatMap(\.elements).isEmpty)
            #expect(await fixture.recordedRequests.filter { $0.method == "thread/items/list" }.count == 2)
            await gateway.retire()
            await fixture.stop()
        } catch { await gateway.retire(); await fixture.stop(); throw error }
    }
}
