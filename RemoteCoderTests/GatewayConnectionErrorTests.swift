import Foundation
import Testing

@testable import RemoteCoder

struct GatewayConnectionErrorTests {
    @Test(.timeLimit(.minutes(1)), arguments: [
        ("Mac mini (M4)", "Mac mini (M4) (127.0.0.1:1)"),
        ("   ", "127.0.0.1:1"),
    ])
    func connectionFailureNamesTheHostItTried(name: String, label: String) async throws {
        let host = GatewayHostConfiguration(
            id: UUID(),
            name: name,
            hostname: "127.0.0.1",
            port: 1,
            authToken: "t"
        )
        let gateway = try GatewayClient(host: host, routes: nil)

        let error = try await #require(throws: GatewayClient.ClientError.self) {
            try await gateway.connectIfNeeded()
        }
        await gateway.retire()

        // The bare transport message names no host, which is what made a
        // wrong active host indistinguishable from a dead gateway.
        #expect(error.errorDescription?.hasPrefix("Could not connect to \(label). ") == true)
    }
}
