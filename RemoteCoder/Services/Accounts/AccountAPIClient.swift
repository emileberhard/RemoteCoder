import Foundation

actor AccountAPIClient {
    private let host: GatewayHostConfiguration
    private let routes: @MainActor @Sendable () -> GatewayRoutes?

    init(host: GatewayHostConfiguration, routes: @escaping @MainActor @Sendable () -> GatewayRoutes?) {
        self.host = host
        self.routes = routes
    }

    func claudeAccounts() async throws -> ClaudeRouterAccountList {
        try await claudeRequest(path: "claude/accounts", method: "GET", body: nil)
    }

    func refreshClaudeAccounts() async throws -> ClaudeRouterAccountList {
        try await claudeRequest(path: "claude/accounts/refresh", method: "POST", body: Data("{}".utf8))
    }

    func setClaudePreference(_ id: String?) async throws -> ClaudeRouterAccountList {
        try await claudeRequest(path: "claude/accounts/preference", method: "PUT",
                                    body: JSONEncoder().encode(ClaudeAccountPreference(account: id)))
    }

    func redeemCodexReset(account: ProviderAccountSnapshot, attempt: ResetRedemptionAttempt) async throws -> AccountResetRedemptionResult {
        struct Input: Encodable { let resetId: String; let idempotencyKey: String; let generation: UInt64 }
        return try await redemptionRequest(path: "accounts/\(account.id)/resets/redeem", accountName: attempt.accountName,
            body: JSONEncoder().encode(Input(resetId: attempt.resetId, idempotencyKey: attempt.canonicalIdempotencyKey, generation: account.generation)))
    }

    func redeemClaudeReset(accountID: String, attempt: ResetRedemptionAttempt) async throws -> AccountResetRedemptionResult {
        struct Input: Encodable { let accountId: String; let resetId: String; let idempotencyKey: String }
        return try await redemptionRequest(path: "claude/accounts/resets/redeem", accountName: attempt.accountName,
            body: JSONEncoder().encode(Input(accountId: accountID, resetId: attempt.resetId, idempotencyKey: attempt.canonicalIdempotencyKey)))
    }

    private func claudeRequest(path: String, method: String, body: Data?) async throws -> ClaudeRouterAccountList {
        let response: ClaudeRouterAccountList = try await request(path: path, method: method, body: body)
        try response.validate()
        return response
    }

    func refreshedDirectory() async throws -> AccountDirectoryResponse {
        try await directory(query: [URLQueryItem(name: "refresh", value: "true"), URLQueryItem(name: "wait", value: "refresh")])
    }

    private func directory(query: [URLQueryItem]) async throws -> AccountDirectoryResponse {
        let response: AccountDirectoryResponse = try await request(path: "accounts", method: "GET", query: query)
        guard response.schemaVersion == 2, Set(response.accounts.map(\.id)).count == response.accounts.count else {
            throw AccountServiceError.invalidResponse
        }
        for account in response.accounts {
            guard account.windows.allSatisfy({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }) else {
                throw AccountServiceError.invalidResponse
            }
        }
        return response
    }

    private struct RouterFailure: Decodable {
        struct Detail: Decodable { let code: String; let message: String? }
        let error: Detail
    }

    private func request<T: Decodable & Sendable>(path: String, method: String, body: Data? = nil,
                                                 query: [URLQueryItem] = []) async throws -> T {
        guard let routes = await routes() else { throw AccountServiceError.unavailable(host.displayName) }
        guard let base = host.gatewayHTTPBaseURL(),
              var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw AccountServiceError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AccountServiceError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: path.hasPrefix("claude/") ? 15 : 100)
        request.httpShouldHandleCookies = false
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(host.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, rawResponse) = try await routes.send(request, traffic: method == "GET" ? .exchange : .mutation) {
            try await $1.data(for: $0)
        }
        guard let response = rawResponse as? HTTPURLResponse, data.count <= 2 * 1_024 * 1_024 else {
            throw AccountServiceError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            if let failure = try? JSONDecoder().decode(RouterFailure.self, from: data) {
                throw AccountServiceError.rejected(failure.error.message ?? failure.error.code)
            }
            if response.statusCode == 404 || response.statusCode == 503 { throw AccountServiceError.unavailable(host.displayName) }
            throw AccountServiceError.rejected("Account request failed (\(response.statusCode)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func redemptionRequest(path: String, accountName: String, body: Data) async throws -> AccountResetRedemptionResult {
        guard let routes = await routes() else { throw AccountServiceError.unavailable(host.displayName) }
        guard let base = host.gatewayHTTPBaseURL() else { throw AccountServiceError.invalidResponse }
        var request = URLRequest(url: base.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpShouldHandleCookies = false
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(host.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        let rawResponse: URLResponse
        do {
            (data, rawResponse) = try await routes.send(request, traffic: .mutation) { try await $1.data(for: $0) }
        } catch {
            if ResetSubmissionCertainty.transport(error) == .unconfirmed {
                throw ResetRedemptionError.unconfirmed("Reset unconfirmed: \(error.localizedDescription)")
            }
            throw ResetRedemptionError.rejected(error.localizedDescription)
        }
        guard let response = rawResponse as? HTTPURLResponse else {
            throw ResetRedemptionError.unconfirmed("Reset unconfirmed: invalid gateway response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let failure = data.count <= 2 * 1_024 * 1_024 ? try? JSONDecoder().decode(RouterFailure.self, from: data) : nil
            if ResetSubmissionCertainty.response(status: response.statusCode, code: failure?.error.code) == .unconfirmed {
                throw ResetRedemptionError.unconfirmed("Reset unconfirmed")
            }
            let code = failure?.error.code
            if ["reauthorization_required", "reset_credential_missing", "reset_credential_unavailable", "codex_credential_unavailable"].contains(code ?? "") {
                throw ResetRedemptionError.rejected(AccountResetMessages.unavailable(code: "reauthorization_required", accountName: accountName))
            }
            throw ResetRedemptionError.rejected(AccountResetMessages.refusal(code: code))
        }
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw ResetRedemptionError.unconfirmed("Reset unconfirmed: invalid gateway response.")
        }
        do { return try JSONDecoder().decode(AccountResetRedemptionResult.self, from: data) }
        catch { throw ResetRedemptionError.unconfirmed("Reset unconfirmed: invalid gateway response.") }
    }
}
