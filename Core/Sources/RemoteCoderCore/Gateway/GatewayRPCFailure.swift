import Foundation

/// RemoteCoder-owned semantics only. Unknown upstream errors remain provider
/// errors; callers never make control-flow decisions from localized messages.
struct GatewayRPCFailure: LocalizedError, Sendable {
    enum Kind: Equatable, Sendable {
        case metadataConflict, voiceCallEnded, capacity
        case automationUnavailable, automationAcknowledgementUnknown
        case compactionDeliveryUncertain, queueChangeUncertain
        case historyPageTooLarge(actualBytes: Int, limitBytes: Int)
        case historyCursorInvalid
        case turnNotRunning(threadID: String, turnID: String?)
        case conversationBusy(retryAfterMs: Int)
        case providerUnresponsive, inputDeliveryUncertain
        case unknown(String)
    }
    struct Details: Decodable, Sendable {
        let kind: Kind
        let retryable: Bool
        let current: ConversationMetadataRecord?

        private enum CodingKeys: String, CodingKey {
            case kind, retryable, current, actualBytes, limitBytes, threadId, turnId, retryAfterMs
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let name = try values.decode(String.self, forKey: .kind)
            switch name {
            case "metadataConflict": kind = .metadataConflict
            case "automationUnavailable": kind = .automationUnavailable
            case "automationAcknowledgementUnknown": kind = .automationAcknowledgementUnknown
            case "voiceCallEnded": kind = .voiceCallEnded
            case "capacity": kind = .capacity
            case "compactionDeliveryUncertain": kind = .compactionDeliveryUncertain
            case "queueChangeUncertain": kind = .queueChangeUncertain
            case "historyPageTooLarge":
                kind = .historyPageTooLarge(actualBytes: try values.decode(Int.self, forKey: .actualBytes),
                                            limitBytes: try values.decode(Int.self, forKey: .limitBytes))
            case "historyCursorInvalid": kind = .historyCursorInvalid
            case "turnNotRunning":
                kind = .turnNotRunning(threadID: try values.decode(String.self, forKey: .threadId),
                                       turnID: try values.decodeIfPresent(String.self, forKey: .turnId))
            case "conversationBusy":
                kind = .conversationBusy(retryAfterMs: try values.decode(Int.self, forKey: .retryAfterMs))
            case "providerUnresponsive": kind = .providerUnresponsive
            case "inputDeliveryUncertain": kind = .inputDeliveryUncertain
            default: kind = .unknown(name)
            }
            retryable = try values.decode(Bool.self, forKey: .retryable)
            current = try values.decodeIfPresent(ConversationMetadataRecord.self, forKey: .current)
        }
    }

    let code: Int
    let message: String
    let kind: Kind
    let retryable: Bool
    private let current: ConversationMetadataRecord?
    var currentMetadata: ConversationMetadata? { current.map(ConversationMetadata.init) }
    var historyPageSize: (actualBytes: Int, limitBytes: Int)? {
        guard case .historyPageTooLarge(let actualBytes, let limitBytes) = kind else { return nil }
        return (actualBytes, limitBytes)
    }
    var errorDescription: String? { message }

    init?(code: Int, message: String, data: JSONValue?) {
        guard let data, let bytes = try? JSONEncoder().encode(data) else { return nil }
        guard let details = try? JSONDecoder().decode(Details.self, from: bytes) else { return nil }
        self.code = code
        self.message = message
        kind = details.kind
        retryable = details.retryable
        current = details.current
    }
}
