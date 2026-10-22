import Foundation

struct ExecutionTarget: Hashable, Codable, Sendable, Identifiable {
    let hostID: UUID
    var id: String { hostID.uuidString }
}

extension AgentProvider {
    func groupID(for identity: ProviderAccountIdentity) -> String { "\(rawValue):\(identity.key)" }
}

struct ProviderAccountIdentity: Codable, Hashable, Sendable {
    let key: String
    let email: String?
    let workspace: String?
}

struct AccountUsageWindow: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let label: String
    let durationMinutes: Int64?
    let usedPercent: Double
    let resetsAt: Double?
    let model: String?

    var remainingPercent: Int { Int((100 - min(100, max(0, usedPercent))).rounded()) }
    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
}

struct ProviderAccountSnapshot: Codable, Hashable, Sendable, Identifiable {
    enum State: String, Codable, Sendable {
        case ready, authenticationRequired, identityMismatch, unavailable, disabled
        var title: String {
            switch self {
            case .ready: "Ready"
            case .authenticationRequired: "Sign-in required"
            case .identityMismatch: "Account identity changed"
            case .unavailable: "Unavailable"
            case .disabled: "Disabled"
            }
        }
    }
    let id: String
    let provider: AgentProvider
    let label: String
    let enabled: Bool
    let generation: UInt64
    let isDefault: Bool
    let identity: ProviderAccountIdentity?
    let plan: String?
    var state: State
    let windows: [AccountUsageWindow]
    let observedAt: Double?
    var stale: Bool
    let error: String?
    let activeTurns: Int
    let incomingCallRoutingId: String?
    var resets: AccountResets? = nil

    var observedDate: Date? { observedAt.map(Date.init(timeIntervalSince1970:)) }
    var isUsable: Bool { enabled && state == .ready }
    var subtitle: String {
        [identity?.email, plan.map { $0.capitalized }].compactMap { $0 }.joined(separator: " · ")
    }
}

struct AccountDirectoryResponse: Codable, Sendable {
    let schemaVersion: Int
    var accounts: [ProviderAccountSnapshot]
    let refreshing: Bool
    var retiredClaudeAccountIds: [UUID] = []

    init(schemaVersion: Int, accounts: [ProviderAccountSnapshot], refreshing: Bool,
         retiredClaudeAccountIds: [UUID] = []) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.refreshing = refreshing
        self.retiredClaudeAccountIds = retiredClaudeAccountIds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 2 else { throw AccountServiceError.invalidResponse }
        accounts = try values.decode([ProviderAccountSnapshot].self, forKey: .accounts)
        refreshing = try values.decode(Bool.self, forKey: .refreshing)
        retiredClaudeAccountIds = try values.decode([UUID].self, forKey: .retiredClaudeAccountIds)
    }
}

enum AccountServiceError: LocalizedError, Sendable {
    case invalidResponse
    case unavailable(String)
    case rejected(String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The gateway returned an invalid account response."
        case .unavailable(let host): "Account management is unavailable on \(host). Update or reconnect that gateway."
        case .rejected(let message): message
        }
    }
}
