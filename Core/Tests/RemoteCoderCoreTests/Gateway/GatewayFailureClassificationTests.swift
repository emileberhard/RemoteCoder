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
        ("timed out", ClientError.requestTimedOut(method: "turn/start"), false, true),
        ("transport", URLError(.networkConnectionLost), false, true),
        ("server error", ClientError.serverError(message: "nope", code: -32000), false, false),
    ]

    @Test(arguments: cases.indices) func classification(_ index: Int) {
        let (name, error, neverSent, unreachable) = Self.cases[index]
        #expect(GatewayClient.failedBeforeSending(error) == neverSent, "\(name)")
        #expect(GatewayClient.meansUnreachable(error) == unreachable, "\(name)")
    }
}
