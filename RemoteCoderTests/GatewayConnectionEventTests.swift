import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct GatewayConnectionEventTests {
    @Test(.timeLimit(.minutes(1))) func connectionEventsReportEachConnectAndDisconnect() async throws {
        let server = try FakeGatewayServer()
        let url = try await server.startURL()
        let gateway = GatewayClient(config: .init(url: url, authToken: "test", hostLabel: "test"), routes: nil)
        var events = await gateway.connectionEvents().makeAsyncIterator()

        try await gateway.connectIfNeeded()
        let connection = try #require(await gateway.connectionIdentity)
        #expect(await events.next() == .connected(connection: connection, route: .configured))

        await gateway.disconnect()
        #expect(await events.next() == .disconnected)

        try await gateway.connectIfNeeded()
        let next = try #require(await gateway.connectionIdentity)
        #expect(next != connection)
        #expect(await events.next() == .connected(connection: next, route: .configured))

        await gateway.retire()
        #expect(await events.next() == .disconnected)
        #expect(await events.next() == nil)
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aFailedConnectAttemptReportsNothing() async throws {
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://127.0.0.1:1")), authToken: "test", hostLabel: "test"),
                                         routes: nil)
        var events = await gateway.connectionEvents().makeAsyncIterator()

        await #expect(throws: (any Error).self) { try await gateway.connectIfNeeded() }
        await gateway.retire()

        #expect(await events.next() == nil)
    }
}
