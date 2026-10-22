import Foundation
import Security
import Testing
@testable import RemoteCoderCore

@MainActor
struct GatewayCredentialTests {
    private func host() -> GatewayHostConfiguration {
        GatewayHostConfiguration(id: UUID(), name: "Test", hostname: "test.example", port: 443, authToken: "synthetic-test-token")
    }

    @Test func migrationRemovesPlaintextOnlyAfterProtectedReadback() throws {
        let suite = "GatewayCredentialTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = host()
        let legacy = try JSONEncoder().encode([original])
        defaults.set(legacy, forKey: "gateway.hosts")
        defaults.set(original.id.uuidString, forKey: "gateway.activeHostID")
        let credentials = MemoryGatewayCredentials()
        credentials.failReadback()
        #expect(throws: (any Error).self) { try HostStore.load(defaults: defaults, credentials: credentials) }
        #expect(defaults.data(forKey: "gateway.hosts") == legacy)
        let working = MemoryGatewayCredentials()
        let migrated = try HostStore.load(defaults: defaults, credentials: working)
        #expect(migrated.hosts.map(\.configuration).contains(original))
        #expect(migrated.activeHostID == original.id)
        #expect(defaults.data(forKey: "gateway.hosts") == nil)
        #expect(defaults.string(forKey: "gateway.activeHostID") == nil)
        #expect(try HostStore.load(defaults: defaults, credentials: working).hosts.map(\.configuration).contains(original))
    }

    @Test func failedSaveDoesNotPublishAnEndpointWithAnUnpersistedCredential() throws {
        let suite = "GatewayCredentialTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = host()
        let credentials = MemoryGatewayCredentials()
        let store = HostStore(hosts: [original], activeHostID: original.id, defaults: defaults, credentials: credentials)
        credentials.fail(with: errSecInteractionNotAllowed)
        var replacement = original
        replacement.hostname = "replacement.example"
        replacement.authToken = "different-synthetic-token"
        #expect(!store.upsert(replacement))
        #expect(store.hosts.map(\.configuration) == [original])
        #expect(store.errorMessage?.contains("locked") == true)
        credentials.fail(with: nil)
        #expect(store.upsert(replacement))
        #expect(store.hosts.map(\.configuration) == [replacement])
        #expect(defaults.data(forKey: "gateway.hosts") == nil)
    }

    @Test func unreadableProtectedStateIsNotReplacedByLegacyOrDefaults() throws {
        let suite = "GatewayCredentialTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryGatewayCredentials()
        let corrupt = Data("not valid configuration".utf8)
        try credentials.write(corrupt)
        #expect(throws: (any Error).self) { try HostStore.load(defaults: defaults, credentials: credentials) }
        #expect(try credentials.read() == corrupt)
    }

    @Test func loadingWithoutASavedConfigurationWritesNothing() throws {
        let suite = "GatewayCredentialTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryGatewayCredentials()
        let seed = host()
        #expect(try HostStore.load(defaults: defaults, credentials: credentials).hosts.isEmpty)
        #expect(try HostStore.load(defaults: defaults, credentials: credentials, seedHosts: [seed]).hosts.map(\.configuration) == [seed])
        #expect(try credentials.read() == nil)
    }

    @Test func transportIsExplicitAndInvalidEndpointsAreRejected() throws {
        var configuration = host()
        #expect(configuration.gatewayWebSocketURL()?.scheme == "wss")
        #expect(configuration.gatewayHTTPBaseURL()?.scheme == "https")
        let previous = configuration
        configuration.transport = .trustedNetwork
        #expect(!configuration.hasSameConnection(as: previous))
        #expect(configuration.gatewayWebSocketURL()?.scheme == "ws")
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        legacy["transport"] = nil
        #expect(try JSONDecoder().decode(GatewayHostConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)).transport == .trustedNetwork)
        configuration.hostname = "host.example@attacker.example/path"
        #expect(configuration.gatewayWebSocketURL() == nil)
        configuration.hostname = "localhost"
        configuration.port = 65536
        #expect(configuration.gatewayHTTPBaseURL() == nil)
    }
}

@MainActor
struct GatewayEnrollmentOwnershipTests {
    @Test(arguments: [true, false])
    func aLateEnrollmentCannotReplaceAnEditedOrCurrentlyOwnedHost(changeEndpoint: Bool) async throws {
        let suite = "GatewayEnrollmentTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = GatewayHostConfiguration(id: UUID(), name: "Test", hostname: "test.example", port: 443, authToken: "synthetic-operator")
        let store = HostStore(hosts: [host], activeHostID: host.id, defaults: defaults, credentials: MemoryGatewayCredentials())
        let client = EnrollmentGate()
        let permission = Permission()
        let work = Task {
            await store.enrollInstallationCredentials(using: client) { _ in permission.allowed }
        }
        await client.waitForStart()
        if changeEndpoint {
            var edited = host
            edited.hostname = "replacement.example"
            #expect(store.upsert(edited))
        } else { permission.allowed = false }
        await client.release()
        await work.value
        #expect(store.hosts.first?.authToken == host.authToken)
        #expect(store.hosts.first?.hostname == (changeEndpoint ? "replacement.example" : "test.example"))
    }

    @MainActor private final class Permission { var allowed = true }
}

private actor EnrollmentGate: GatewayCredentialEnrolling {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private let stream: AsyncStream<Void>
    private let completion: AsyncStream<Void>.Continuation

    init() { (stream, completion) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    func waitForStart() async {
        if !entered { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { completion.finish() }
    func enroll(host: GatewayHostConfiguration, installationID: String) async throws -> String {
        entered = true
        waiting?.resume()
        waiting = nil
        for await _ in stream { break }
        try Task.checkCancellation()
        return "rc1.\(installationID).synthetic-enrolled-token"
    }
}
