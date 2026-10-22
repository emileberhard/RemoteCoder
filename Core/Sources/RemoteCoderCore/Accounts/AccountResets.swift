import Foundation

struct AccountResets: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case known, unavailable }
    let state: State
    let observedAt: Double?
    let available: Int?
    let offers: [AccountResetOffer]?
    let error: String?

    var knownCount: Int? { state == .known ? available : nil }

    func isStale(now: Date) -> Bool {
        guard state == .known, let observedAt else { return true }
        return now.timeIntervalSince1970 - observedAt > 900
    }
}

struct AccountResetOffer: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String?
    let remaining: Int
    let expiresAt: Double?
    let usableNow: Bool?
    let requiresLimit: Bool?
    let clears: [String]?

    var displayTitle: String { title ?? "Usage reset" }

    func canUse(now: Date) -> Bool {
        remaining > 0 && usableNow != false && (expiresAt.map { $0 > now.timeIntervalSince1970 } ?? true)
    }
}

struct AccountResetRedemptionResult: Decodable, Equatable, Sendable {
    enum Outcome: String, Decodable, Sendable { case reset, alreadyRedeemed, notNeeded, refused }
    let outcome: Outcome
    let reason: String?

    var message: String {
        switch outcome {
        case .reset: "Reset used"
        case .alreadyRedeemed: "Reset already used"
        case .notNeeded: "No reset needed"
        case .refused: AccountResetMessages.refusal(code: reason)
        }
    }
}

struct ResetRedemptionAttempt: Codable, Equatable, Sendable {
    let resetId: String
    let title: String
    let idempotencyKey: UUID
    let hostID: UUID
    let gatewayAccountID: String
    let accountName: String

    var canonicalIdempotencyKey: String { idempotencyKey.uuidString.lowercased() }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(resetId, forKey: .resetId)
        try values.encode(title, forKey: .title)
        try values.encode(canonicalIdempotencyKey, forKey: .idempotencyKey)
        try values.encode(hostID, forKey: .hostID)
        try values.encode(gatewayAccountID, forKey: .gatewayAccountID)
        try values.encode(accountName, forKey: .accountName)
    }
}

enum ResetSubmissionCertainty: Equatable, Sendable {
    case refused, unconfirmed

    static func response(status: Int, code: String?) -> Self {
        status == 504 && code == "redeem_unconfirmed" ? .unconfirmed : .refused
    }

    static func transport(_ error: any Error) -> Self {
        guard let error = error as? URLError else { return .unconfirmed }
        if GatewayRoute.neverReachedGateway(error) { return .refused }
        switch error.code {
        case .badURL, .unsupportedURL: return .refused
        default: return .unconfirmed
        }
    }
}

enum AccountResetMessages {
    static func unavailable(code: String?, accountName: String) -> String {
        switch code {
        case "reauthorization_required", "reset_credential_missing", "reset_credential_unavailable", "codex_credential_unavailable":
            "Sign-in needed for \(accountName). Ask an agent to reconnect it."
        default: "Resets unavailable. Refresh to try again."
        }
    }

    static func refusal(code: String?) -> String {
        switch code {
        case "reauthorization_required", "reset_credential_missing", "reset_credential_unavailable", "codex_credential_unavailable":
            "Sign-in needed. Ask an agent to reconnect this account."
        case "gateway_stopping", "accounts_busy", "router_unavailable", "router_stopping", "router_key_unavailable",
             "router_retry_later", "account_management_unavailable": "Gateway unavailable. Try again shortly."
        case "reset_account_changed": "Account changed. Refresh it before using a reset."
        case "noCredit": "No resets left. Refresh this account."
        case "already_used", "alreadyRedeemed": "Reset already used. Refresh this account."
        case "cooldown": "Reset is cooling down. Try again later."
        case "ineligible": "This account is not eligible for a reset."
        case "redeem_in_progress", "redeem_unconfirmed_pending": "Another reset is pending. Try again later."
        default: "Reset declined. Refresh this account."
        }
    }
}

enum ResetRedemptionError: LocalizedError, Sendable {
    case unconfirmed(String), rejected(String)

    var errorDescription: String? {
        switch self {
        case .unconfirmed(let message), .rejected(let message): message
        }
    }

    var isUnconfirmed: Bool {
        if case .unconfirmed = self { return true }
        return false
    }
}

enum ResetRedemptionState: Equatable, Sendable {
    case idle
    case submitting(ResetRedemptionAttempt)
    case retrying(ResetRedemptionAttempt)
    case unconfirmed(ResetRedemptionAttempt, String)
    case retryRefused(ResetRedemptionAttempt, String)
    case completed(AccountResetRedemptionResult)
    case failed(String)

    var attempt: ResetRedemptionAttempt? {
        switch self {
        case .submitting(let attempt), .retrying(let attempt), .unconfirmed(let attempt, _), .retryRefused(let attempt, _): attempt
        default: nil
        }
    }
    var isUnresolved: Bool { attempt != nil }
    var isSubmitting: Bool {
        switch self {
        case .submitting, .retrying: true
        default: false
        }
    }
    var canRetry: Bool {
        switch self {
        case .unconfirmed, .retryRefused: true
        default: false
        }
    }
    var canForget: Bool {
        switch self {
        case .retryRefused: true
        default: false
        }
    }
    var message: String? {
        switch self {
        case .idle, .submitting, .retrying: nil
        case .unconfirmed(_, let message), .retryRefused(_, let message), .failed(let message): message
        case .completed(let result): result.message
        }
    }

    init(restoring attempt: ResetRedemptionAttempt) {
        self = .unconfirmed(attempt, "Reset unconfirmed")
    }

    mutating func begin(offer: AccountResetOffer, key: UUID, hostID: UUID, gatewayAccountID: String, accountName: String) -> ResetRedemptionAttempt? {
        guard !isUnresolved else { return nil }
        let attempt = ResetRedemptionAttempt(resetId: offer.id, title: offer.displayTitle, idempotencyKey: key,
                                             hostID: hostID, gatewayAccountID: gatewayAccountID, accountName: accountName)
        self = .submitting(attempt)
        return attempt
    }

    mutating func retry() -> ResetRedemptionAttempt? {
        switch self {
        case .unconfirmed(let attempt, _), .retryRefused(let attempt, _):
            self = .retrying(attempt)
            return attempt
        default: return nil
        }
    }

    mutating func resolve(_ result: AccountResetRedemptionResult, key: UUID) {
        guard isSubmitting, let attempt, attempt.idempotencyKey == key else { return }
        if case .retrying = self, result.outcome == .refused {
            self = .retryRefused(attempt, result.message + " The original outcome is still unknown.")
        } else { self = .completed(result) }
    }

    mutating func fail(_ message: String, key: UUID, unconfirmed: Bool) {
        guard isSubmitting, let attempt, attempt.idempotencyKey == key else { return }
        if unconfirmed { self = .unconfirmed(attempt, message) }
        else if case .retrying = self {
            self = .retryRefused(attempt, message + " The original outcome is still unknown.")
        } else { self = .failed(message) }
    }
}
