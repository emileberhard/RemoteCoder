import Foundation
import Testing
@testable import RemoteCoderCore

struct GatewayDictationCredentialTests {
    private let host = GatewayHostConfiguration(id: UUID(), name: "Test", hostname: "gateway.example", port: 443, authToken: "gateway-secret")

    @Test func persistedCredentialsWorkOfflineAndOnlyRejectedKeysRefresh() async throws {
        let storage = MemoryGatewayCredentials()
        let remote = DictationCredentialSource()
        let credentials = GatewayDictationCredentials(host: host, storage: storage, fetch: { try await remote.fetch() })
        #expect(try await credentials.cachedOrigin() == nil)
        let original = try await credentials.current()
        #expect(try await credentials.cachedOrigin() == original.origin)
        let reopened = GatewayDictationCredentials(host: host, storage: storage, fetch: { throw URLError(.notConnectedToInternet) })
        #expect(try await reopened.current() == original)
        #expect(await remote.count == 1)
        let replacement = try await credentials.refresh(rejecting: original.key)
        #expect(replacement.key != original.key)
        #expect(try await credentials.refresh(rejecting: original.key) == replacement)
        #expect(try await reopened.current() == replacement)
        #expect(await remote.count == 2)
    }

    @Test func changingAGatewaysConnectionCannotReuseItsPreviousDictationKey() async throws {
        let storage = MemoryGatewayCredentials()
        let remote = DictationCredentialSource()
        _ = try await GatewayDictationCredentials(host: host, storage: storage, fetch: { try await remote.fetch() }).current()
        var edited = host
        edited.hostname = "replacement.example"
        let replacement = GatewayDictationCredentials(host: edited, storage: storage, fetch: { throw URLError(.notConnectedToInternet) })
        await #expect(throws: URLError.self) { try await replacement.current() }
    }

    @Test func aFailedRefreshPreservesTheProtectedCredentialForALaterRetry() async throws {
        let storage = MemoryGatewayCredentials()
        let remote = DictationCredentialSource()
        let initial = try await GatewayDictationCredentials(host: host, storage: storage, fetch: { try await remote.fetch() }).current()
        let before = try storage.read()
        let offline = GatewayDictationCredentials(host: host, storage: storage, fetch: { throw URLError(.notConnectedToInternet) })
        await #expect(throws: URLError.self) { try await offline.refresh(rejecting: initial.key) }
        #expect(try storage.read() == before)
    }
}

private actor DictationCredentialSource {
    private(set) var count = 0
    func fetch() throws -> DictationRouterCredential {
        count += 1
        return try DictationRouterCredential(origin: try #require(URL(string: "https://dictation.example")), key: "dictation-\(count)")
    }
}
