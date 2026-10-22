import Foundation
import SpeechKit
import Testing
@testable import RemoteCoder

struct GatewaySpeechAccessTests {
    private let host = GatewayHostConfiguration(
        id: UUID(), name: "Mac Mini", hostname: "mini.example", port: 8787, authToken: "rc1.phone.secret"
    )

    @Test func providersRelayThroughTheHostWithItsCredential() async throws {
        guard case .relay(let relay) = try await GatewaySpeechAccess(host: host, routes: .isolated(host)).access(to: .assemblyAI) else {
            Issue.record("AssemblyAI must relay through the gateway")
            return
        }
        #expect(relay.baseURL.absoluteString == "https://mini.example:8787/speech/assemblyai")
        #expect(relay.bearerToken == "rc1.phone.secret")
        #expect(relay.transport == nil)

        var trusted = host
        trusted.transport = .trustedNetwork
        guard case .relay(let azure) = try await GatewaySpeechAccess(host: trusted, routes: .isolated(trusted)).access(to: .azure) else {
            Issue.record("Azure must relay through the gateway")
            return
        }
        #expect(azure.baseURL.absoluteString == "http://mini.example:8787/speech/azure")
    }

    @Test func speechFollowsTheRelayTheGatewayConnectedOver() async throws {
        let directory = URL.temporaryDirectory.appending(path: "speech-routes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try GatewayLANEndpoint(host: "mini.local", port: 8789, spkiSHA256: Data(repeating: 1, count: 32))
        let relay = try GatewayRelayEndpoint(proxyHost: "relay.invalid", proxyPort: 443, proxySPKISHA256: Data(repeating: 2, count: 32),
                                             targetHost: "mini.relay.invalid", targetPort: 20001, username: "relay", password: "secret")
        let learned = { (key: String, value: Data) throws -> Data in
            try JSONSerialization.data(withJSONObject: ["learnedFrom": host.connectionSummary,
                                                        key: JSONSerialization.jsonObject(with: value)])
        }
        try learned("endpoint", JSONEncoder().encode(endpoint)).write(to: directory.appending(path: "lan-endpoint.json"))
        let storage = MemoryGatewayCredentials()
        try storage.write(learned("relay", JSONEncoder().encode(relay)))
        let routes = GatewayRoutes(host: host, directory: directory, relayStorage: storage, policy: .production, observeLocalNetwork: { _ in })
        let access = GatewaySpeechAccess(host: host, routes: routes)

        guard case .relay(let configured) = try await access.access(to: .openAI) else { Issue.record("OpenAI must relay"); return }
        #expect(configured.baseURL.absoluteString == "https://mini.example:8787/speech/openai")
        #expect(configured.transport == nil)

        await routes.connected(over: .relay(relay), startedAt: .now, afterFailing: [])
        guard case .relay(let relayed) = try await access.access(to: .openAI),
              case .relay(let again) = try await access.access(to: .gemini) else { Issue.record("Speech must relay"); return }
        #expect(relayed.baseURL.absoluteString == "https://mini.relay.invalid:20001/speech/openai")
        #expect(again.baseURL.absoluteString == "https://mini.relay.invalid:20001/speech/gemini")
        #expect(relayed.transport != nil)
        #expect(relayed.transport == again.transport)
        await routes.retire()
    }

    @Test func relayRejectionsNameTheHostProviderAndCause() {
        let access = GatewaySpeechAccess(host: host, routes: .isolated(host))
        let cases: [(String, GatewaySpeechProvider, String)] = [
            ("credentialsUnavailable", .gemini,
             "Gemini through Mac Mini (mini.example:8787) failed: the gateway cannot read its llm-router key."),
            ("notPermitted", .openAI,
             "OpenAI through Mac Mini (mini.example:8787) failed: this device is not in the gateway's RC_CODEX_GATEWAY_SPEECH_CLIENTS."),
            ("unauthorized", .elevenLabs,
             "ElevenLabs through Mac Mini (mini.example:8787) failed: the gateway rejected this device's credential."),
            ("quotaExhausted", .assemblyAI,
             "AssemblyAI through Mac Mini (mini.example:8787) failed: the gateway refused the request (quotaExhausted)."),
        ]
        for (kind, provider, message) in cases {
            let rejection = SpeechKitError.relayRejected(kind: kind)
            let reported: [any Error] = [
                rejection,
                RealtimeDictationError.connectionFailed(rejection),
                RealtimeDictationError.streamFailed(rejection),
            ]
            for error in reported {
                #expect(access.explain(error, provider: provider).localizedDescription == message)
            }
        }
    }

    @Test func unmarkedFailuresPassThroughUnchanged() {
        let access = GatewaySpeechAccess(host: host, routes: .isolated(host))
        let unmarked: [any Error] = [
            SpeechKitError.httpFailure(
                statusCode: 503,
                body: #"{"remoteCoderSpeechError":{"kind":"credentialsUnavailable"}}"#
            ),
            SpeechKitError.httpFailure(statusCode: 404, body: ""),
            SpeechKitError.webSocketHandshakeFailed(statusCode: 401),
            SpeechKitError.webSocketHandshakeFailed(statusCode: 404),
            SpeechKitError.webSocketClosed(code: 4403, reason: "notPermitted"),
            SpeechKitError.webSocketClosed(code: 1008, reason: "invalid model"),
            RealtimeDictationError.streamFailed(SpeechKitError.webSocketClosed(code: 1008, reason: "invalid model")),
            RealtimeDictationError.finalizationTimedOut,
            CancellationError(),
        ]
        for error in unmarked {
            #expect(!(access.explain(error, provider: .openAI) is GatewaySpeechFailure))
        }
    }
}
