import Foundation
import Security
import Testing
@testable import RemoteCoder

@Suite struct GatewayRouteTests {
    struct GatewayLANEndpointTests {
        @Test func decodesTheGatewayHealthField() throws {
            let json = Data(#"{"host":"workstation.local","port":8789,"spkiSha256":"qLfoLbRhblXl6JWyFO5QiGNqnt4JlGn5VU+ApdkGuVI="}"#.utf8)
            let endpoint = try JSONDecoder().decode(GatewayLANEndpoint.self, from: json)
            #expect(endpoint.host == "workstation.local")
            #expect(endpoint.port == 8789)
            #expect(endpoint.spkiSHA256 == Data(base64Encoded: "qLfoLbRhblXl6JWyFO5QiGNqnt4JlGn5VU+ApdkGuVI="))
        }

        @Test(arguments: [
            #"{"host":"evil.local/x","port":8789,"spkiSha256":"qLfoLbRhblXl6JWyFO5QiGNqnt4JlGn5VU+ApdkGuVI="}"#,
            #"{"host":"user@mini.local","port":8789,"spkiSha256":"qLfoLbRhblXl6JWyFO5QiGNqnt4JlGn5VU+ApdkGuVI="}"#,
            #"{"host":"","port":8789,"spkiSha256":"qLfoLbRhblXl6JWyFO5QiGNqnt4JlGn5VU+ApdkGuVI="}"#,
            #"{"host":"mini.local","port":0,"spkiSha256":"qLfoLbRhblXl6JWyFO5QiGNqnt4JlGn5VU+ApdkGuVI="}"#,
            #"{"host":"mini.local","port":65536,"spkiSha256":"qLfoLbRhblXl6JWyFO5QiGNqnt4JlGn5VU+ApdkGuVI="}"#,
            #"{"host":"mini.local","port":8789,"spkiSha256":"AAAA"}"#,
        ])
        func rejectsAnEndpointThatCannotBeDialedOrPinned(json: String) {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(GatewayLANEndpoint.self, from: Data(json.utf8)) }
        }
    }

    struct GatewaySPKIPinTests {
        private static let p256 = "MIIBhDCCASugAwIBAgIUQR+3J0/Nyn8OIlXMlRpsTm14HIwwCgYIKoZIzj0EAwIwGDEWMBQGA1UEAwwNZ2F0ZXdheS5sb2NhbDAeFw0yNjA5MjMyMTE2NDZaFw0zNjA5MjAyMTE2NDZaMBgxFjAUBgNVBAMMDWdhdGV3YXkubG9jYWwwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARQehRLy0H+QH5Yovwi5wnSxu0V02JBp0RFMBpPmsVZyUvZHQggJz4WSHwmEaJq/cOw48GFZl7mFofVznU7IHDio1MwUTAdBgNVHQ4EFgQUkw1/GXJG1W3NWZiFBG/ueP9PnXcwHwYDVR0jBBgwFoAUkw1/GXJG1W3NWZiFBG/ueP9PnXcwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiBDFbuVjkmq40RZQM8PCPExUGEFGYE4g/YKNEVZ0YaexAIgZLRBln11t3YgsP9sC4+wFDoaBbeuVEeOiJGi/qYCn/0="
        private static let p256Pin = "qLfoLbRhblXl6JWyFO5QiGNqnt4JlGn5VU+ApdkGuVI="
        private static let p384 = "MIIBwzCCAUigAwIBAgIUHlCNYlh63nFjDJldMKZcz+vcTw4wCgYIKoZIzj0EAwIwGDEWMBQGA1UEAwwNZ2F0ZXdheS5sb2NhbDAeFw0yNjA5MjMyMTE2NDZaFw0zNjA5MjAyMTE2NDZaMBgxFjAUBgNVBAMMDWdhdGV3YXkubG9jYWwwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAR62UW9Mcxx3wXrf0HhU97qL1Ixd+3FKcFtU+6yKLc3nkUV2pfcXGXgKcJMffvfordySCjJTIyb/ct+hBQNxzDtKH9CWMlGpF9l2lRrtG4dr3fu9elULicQtde+DTSSgW6jUzBRMB0GA1UdDgQWBBQ8iY7YJsccF/eeUeayoPyn+X2O3DAfBgNVHSMEGDAWgBQ8iY7YJsccF/eeUeayoPyn+X2O3DAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA2kAMGYCMQDqL2VjsjCWpQ9JMQlQNkzbAHO2asUsgVEzKUZZ7tKdlt6wOaMDOPS1GMHcSUHfo6ICMQCsEtbrzrwzOqa0ELEJo7MlouzknoCI6/GhfN18KydBjYsBJg0hTva+aSOosn1rZ1E="
        private static let p384Pin = "+/9PJbrOysPIFtWAJ1amXqi887W7s5TCPooHIDIHiAM="
        private static let rsa = "MIIDETCCAfmgAwIBAgIUKFwICtC7aPyMvuawVNHw/+15KRYwDQYJKoZIhvcNAQELBQAwGDEWMBQGA1UEAwwNZ2F0ZXdheS5sb2NhbDAeFw0yNjA5MjMyMTE2NDZaFw0zNjA5MjAyMTE2NDZaMBgxFjAUBgNVBAMMDWdhdGV3YXkubG9jYWwwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC556BKlr0v5bI1afwp4d4MY2lETzHLiXYQp+GxsMEAp3gyKoi7mUdwDoOZPeQEzwB8+fLyPs+Zy2z+Jk/CnCIS7JM3jr+OVrm8StqUJ5ugjlzCxZLBU7UTNGHPqjJJPa6Kg3jYnEf9w5UUm9tubuzQlM+244UNQt2Vbq91iWSI30+8MQRGH28jmW+lBb7dAELfAX7bWBs+yj5qCbUFxKouQ4K4WSzsMUSbPR3nGZnbR2LiR3mUQLZvwyDUyhGv25dwKt+2z5QNwePcXQugd5kpPiquIWBcuGJmrRgMM2SVEwJ78kV5QahvZjoB6//Q8/dnnEbWAf9AIIlT3P3kC/OhAgMBAAGjUzBRMB0GA1UdDgQWBBS2cZMSZ/K6wods/MWFyibzTtzgijAfBgNVHSMEGDAWgBS2cZMSZ/K6wods/MWFyibzTtzgijAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQBwtlcYjA8CA/t+5mw4WxaG4uLe4MY8SA6/Bd+mOuEQRd311M38XiqOTfygVyxU9fUOokQ49Q8MEDYKrCvEokE+TPz2Fb+udGbcX9QjAZ4Tb5Hf+NJS6jOlCLuy0d9y+FToWMeDbglvkHhDNt1wI3OPHCKimoY8CVTTo3Pln8BL/H9eqhwXi6KhkXxptP3WgDA2p9JAjPFbSSahJN32x7eK1UKdQfa+x/j6ghpyDDr+I8xrsFQzcDgxz9Em3zvcGiBS2jMygggycSC8bqIi7lf3F9DlpH7cu99C7w8iubg11N0URxebHIky8CFNtHOYj/Oh1a3mV6vEJx+3vKWOcjcb"
        private static let rsaPin = "/iaBxJ3xnU2KM2T/znh3bXDnCFyQ5ZrxbQxnZENaZp4="

        private static func trust(_ certificate: String) throws -> SecTrust {
            let der = try #require(Data(base64Encoded: certificate))
            let leaf = try #require(SecCertificateCreateWithData(nil, der as CFData))
            var trust: SecTrust?
            #expect(SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
            return try #require(trust)
        }

        private static func pin(_ base64: String) throws -> Data {
            try #require(Data(base64Encoded: base64))
        }

        @Test func acceptsTheGatewayKeyItWasPinnedTo() throws {
            let gateway = try Self.trust(Self.p256)
            let pin = try Self.pin(Self.p256Pin)
            #expect(GatewaySPKIPin.matches(gateway, pin: pin))
        }

        @Test func rejectsAnyOtherKey() throws {
            let gateway = try Self.trust(Self.p256)
            let otherKeyPin = try Self.pin(Self.rsaPin)
            #expect(!GatewaySPKIPin.matches(gateway, pin: Data(repeating: 0, count: 32)))
            #expect(!GatewaySPKIPin.matches(gateway, pin: otherKeyPin))
        }

        @Test func rejectsKeysThatAreNotP256EvenWithTheirOwnPin() throws {
            let p384 = try Self.trust(Self.p384)
            let p384Pin = try Self.pin(Self.p384Pin)
            let rsa = try Self.trust(Self.rsa)
            let rsaPin = try Self.pin(Self.rsaPin)
            #expect(!GatewaySPKIPin.matches(p384, pin: p384Pin))
            #expect(!GatewaySPKIPin.matches(rsa, pin: rsaPin))
        }
    }

    struct GatewayRouteFallbackTests {
        @Test(.timeLimit(.minutes(1))) func aFailedLANAttemptFallsBackWithoutEndingNotificationStreams() async throws {
            let server = try FakeGatewayServer()
            await server.notifyAfterInitialize("test/afterInitialize")
            let port = try await server.start()
            let directory = URL.temporaryDirectory.appending(path: "gateway-routes-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let host = GatewayHostConfiguration(id: UUID(), name: "Test", hostname: "127.0.0.1", port: Int(port),
                authToken: "test", transport: .trustedNetwork)
            let unreachable = try GatewayLANEndpoint(host: "127.0.0.1", port: 1, spkiSHA256: Data(repeating: 1, count: 32))
            let cache: JSONValue = .object([
                "learnedFrom": .string(host.connectionSummary),
                "endpoint": .object(["host": .string(unreachable.host), "port": .number(1),
                                     "spkiSha256": .string(unreachable.spkiSHA256.base64EncodedString())]),
            ])
            try JSONEncoder().encode(cache).write(to: directory.appending(path: "lan-endpoint.json"))
            let routes = GatewayRoutes(host: host, directory: directory, relayStorage: MemoryGatewayCredentials(), policy: .production, observeLocalNetwork: { $0.yield(GatewayNetworkPath(identity: UUID(), localNetworkAvailable: true)) })
            while await routes.lanCandidate() == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await routes.lanCandidate() == unreachable)

            let url = try #require(host.gatewayWebSocketURL())
            let gateway = GatewayClient(config: .init(url: url, authToken: "test", hostLabel: "test"), routes: routes)
            let notifications = await gateway.notifications()
            try await gateway.connectIfNeeded()

            #expect(await gateway.isConnected)
            #expect(await routes.lanCandidate() == nil)
            var iterator = notifications.makeAsyncIterator()
            let methods = [await iterator.next()?.method, await iterator.next()?.method]
            #expect(methods == ["daemon/ready", "test/afterInitialize"])
            await gateway.retire()
            await routes.retire()
            await server.stop()
        }
    }

}
