import Foundation

struct DictationRouterCredential: Codable, Equatable, Sendable {
    let origin: URL
    let key: String

    init(origin: URL, key: String) throws {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme), parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", !key.isEmpty,
              key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw GatewayCredentialFailure.invalidData
        }
        self.origin = origin
        self.key = key
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(origin: values.decode(URL.self, forKey: .origin), key: values.decode(String.self, forKey: .key))
    }
}

actor GatewayDictationCredentials {
    private struct Cached: Codable {
        let host: GatewayHostConfiguration
        let credential: DictationRouterCredential
    }

    private let host: GatewayHostConfiguration
    private let storage: any GatewayCredentialStorage
    private let fetch: @Sendable () async throws -> DictationRouterCredential
    private var pending: Task<DictationRouterCredential, any Error>?

    init(host: GatewayHostConfiguration, storage: any GatewayCredentialStorage,
         fetch: @escaping @Sendable () async throws -> DictationRouterCredential) {
        self.host = host
        self.storage = storage
        self.fetch = fetch
    }

    deinit { pending?.cancel() }

    func cachedOrigin() throws -> URL? {
        try stored()?.origin
    }

    func current() async throws -> DictationRouterCredential {
        if let pending { return try await pending.value }
        if let credential = try stored() { return credential }
        return try await fetchAndStore()
    }

    func refresh(rejecting key: String) async throws -> DictationRouterCredential {
        if let pending { return try await pending.value }
        if let credential = try stored(), credential.key != key { return credential }
        return try await fetchAndStore()
    }

    private func stored() throws -> DictationRouterCredential? {
        guard let data = try storage.read() else { return nil }
        let cached = try JSONDecoder().decode(Cached.self, from: data)
        return cached.host.hasSameConnection(as: host) ? cached.credential : nil
    }

    private func fetchAndStore() async throws -> DictationRouterCredential {
        let task = Task { [fetch, storage, host] in
            let credential = try await fetch()
            try Task.checkCancellation()
            try storage.write(JSONEncoder().encode(Cached(host: host, credential: credential)))
            return credential
        }
        pending = task
        defer { pending = nil }
        return try await task.value
    }
}
