import Foundation

actor ResetRedemptionStore {
    private let url: URL
    private let provider: AgentProvider
    private var pending: [String: ResetRedemptionAttempt]?

    init(storage: HostStorage, provider: AgentProvider) {
        self.provider = provider
        url = storage.directory(for: .device).appending(path: "\(provider.rawValue)-reset-attempts-v1.json")
    }

    func load() throws -> [String: ResetRedemptionAttempt] {
        if let pending { return pending }
        guard FileManager.default.fileExists(atPath: url.path) else {
            pending = [:]
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1_024 else { throw AccountServiceError.invalidResponse }
        var loaded = try JSONDecoder().decode([String: ResetRedemptionAttempt].self, from: data)
        guard loaded.count <= 128, loaded.allSatisfy({ !$0.key.isEmpty && !$0.value.resetId.isEmpty && !$0.value.gatewayAccountID.isEmpty }) else {
            throw AccountServiceError.invalidResponse
        }
        let retired = provider == .codex ? loaded.filter { UUID(uuidString: $0.value.gatewayAccountID) != nil } : [:]
        if !retired.isEmpty {
            for (key, attempt) in retired {
                loaded[key] = ResetRedemptionAttempt(resetId: attempt.resetId, title: attempt.title, idempotencyKey: attempt.idempotencyKey,
                    hostID: attempt.hostID, gatewayAccountID: "default-codex", accountName: attempt.accountName)
            }
            try write(loaded)
        }
        pending = loaded
        return loaded
    }

    func save(_ attempt: ResetRedemptionAttempt, accountID: String) throws {
        var updated = try load()
        guard updated[accountID] == nil || updated[accountID] == attempt else { throw AccountServiceError.invalidResponse }
        updated[accountID] = attempt
        guard updated.count <= 128 else { throw AccountServiceError.rejected("Too many unconfirmed resets.") }
        try write(updated)
    }

    func resolve(accountID: String, key: UUID) throws {
        var updated = try load()
        guard updated[accountID]?.idempotencyKey == key else { return }
        updated.removeValue(forKey: accountID)
        try write(updated)
    }

    private func write(_ updated: [String: ResetRedemptionAttempt]) throws {
        let data = try JSONEncoder().encode(updated)
        guard data.count <= 128 * 1_024 else { throw AccountServiceError.rejected("Pending reset storage is full.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        pending = updated
    }
}
