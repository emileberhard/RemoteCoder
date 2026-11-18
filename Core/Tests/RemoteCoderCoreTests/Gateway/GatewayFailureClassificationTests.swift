import Foundation
import Testing
@testable import RemoteCoderCore

struct GatewayFailureClassificationTests {
    typealias ClientError = GatewayClient.ClientError

    static let cases: [(String, any Error, Bool, Bool)] = [
        ("not connected", ClientError.notConnected, true, true),
        ("connection failed", ClientError.connectionFailed(host: "mini", reason: "refused"), true, true),
        ("credentials rejected", ClientError.credentialsRejected(host: "mini"), true, true),
        ("not ready", ClientError.gatewayNotReady(host: "mini", reason: "starting"), true, true),
        ("retired", ClientError.retired, true, true),
        ("invalid url", ClientError.invalidURL, true, false),
        ("closed after writing", ClientError.connectionClosed, false, true),
        ("restarting after writing", ClientError.gatewayRestarting, false, true),
        ("timed out on a live connection", ClientError.requestTimedOut(method: "turn/start"), false, false),
        ("transport", URLError(.networkConnectionLost), false, true),
        ("server error", ClientError.serverError(message: "nope", code: -32000), false, false),
    ]

    @Test(arguments: cases.indices) func classification(_ index: Int) {
        let (name, error, neverSent, unreachable) = Self.cases[index]
        #expect(GatewayClient.failedBeforeSending(error) == neverSent, "\(name)")
        #expect(GatewayClient.meansUnreachable(error) == unreachable, "\(name)")
    }
}

struct GatewayConnectNowTests {
    @Test(.timeLimit(.minutes(1))) func aSilentHostIsGivenUpOnAtTheLimit() async throws {
        let gateway = GatewayClient(config: .init(url: try #require(URL(string: "ws://192.0.2.1:8787")), authToken: "test",
                                                  hostLabel: "test"), routes: nil)
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await gateway.connectNow(within: .milliseconds(300)) }
        #expect(started.duration(to: .now) < .seconds(3))
        await gateway.retire()
    }
}
