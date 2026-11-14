import Foundation
import Security
import SpeechKit
import Testing
@testable import RemoteCoder

struct GatewaySpeechAccessTests {
    private let host = GatewayHostConfiguration(id: UUID(), name: "Test", hostname: "offline.invalid", port: 443, authToken: "gateway-secret")

    @Test(arguments: GatewaySpeechProvider.allCases)
    func everySupportedProviderUsesTheDirectRouter(provider: GatewaySpeechProvider) async throws {
        let remote = DictationAccessSource()
        let access = access(remote: remote)
        guard case .router(let router) = try await access.access(to: provider) else {
            Issue.record("Dictation must use the router directly")
            return
        }
        #expect(router.origin.absoluteString == "https://dictation.example")
        #expect(router.key == "dictation-key-1")
        #expect(router.transport != nil)
        guard case .router(let again) = try await access.access(to: provider) else { return }
        #expect(router.transport === again.transport)
    }

    @Test(arguments: [401, 403])
    func onlyUnauthorizedResponsesRefetchAndRetry(status: Int) async throws {
        let remote = DictationAccessSource()
        let access = access(remote: remote)
        let attempt = DictationAccessAttempt()
        do {
            let key = try await access.perform { providerAccess in
                guard case .router(let router) = providerAccess else { throw URLError(.badURL) }
                if await attempt.next() == 1 { throw SpeechKitError.httpFailure(statusCode: status, body: "") }
                return router.key
            }
            #expect(status == 401)
            #expect(key == "dictation-key-2")
        } catch {
            #expect(status == 403)
        }
        #expect(await remote.count == (status == 401 ? 2 : 1))
    }

    @Test func repeatedUnauthorizedResponsesStopAfterOneRefresh() async throws {
        let remote = DictationAccessSource()
        let access = access(remote: remote)
        let attempt = DictationAccessAttempt()
        await #expect(throws: SpeechKitError.self) {
            try await access.perform { _ in
                _ = await attempt.next()
                throw SpeechKitError.httpFailure(statusCode: 401, body: "")
            } as Void
        }
        #expect(await attempt.count == 2)
        #expect(await remote.count == 2)
    }

    @Test func webSocketAuthenticationRefusalRefreshesTheCredentialForSavedAudio() async throws {
        let remote = DictationAccessSource()
        let access = access(remote: remote)
        _ = try await access.access(to: .elevenLabs)
        try await access.refreshIfUnauthorized(RealtimeDictationError.connectionFailed(SpeechKitError.webSocketHandshakeFailed(statusCode: 401)))
        #expect(await remote.count == 2)
    }

    @Test func dictationKeychainItemsAreDeviceOnlyAndSeparatedByHost() throws {
        let other = UUID()
        let first = KeychainGatewayCredentials(scope: .dictation(hostID: host.id))
        let second = KeychainGatewayCredentials(scope: .dictation(hostID: other))
        let account = "dictation-router-v1.\(host.id.uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "emileberhard.RemoteCoder.gateway-configuration",
            kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
        defer { SecItemDelete(query as CFDictionary) }
        let data = Data("synthetic-dictation-key".utf8)
        try first.write(data)
        #expect(try first.read() == data)
        #expect(try second.read() == nil)
        var attributesQuery = query
        attributesQuery[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(attributesQuery as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
    }

    private func access(remote: DictationAccessSource) -> GatewaySpeechAccess {
        GatewaySpeechAccess(host: host, credentials: GatewayDictationCredentials(host: host,
            storage: MemoryGatewayCredentials(), fetch: { try await remote.fetch() }))
    }
}

private actor DictationAccessSource {
    private(set) var count = 0
    func fetch() throws -> DictationRouterCredential {
        count += 1
        guard let origin = URL(string: "https://dictation.example") else { throw URLError(.badURL) }
        return try DictationRouterCredential(origin: origin, key: "dictation-key-\(count)")
    }
}

private actor DictationAccessAttempt {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}
