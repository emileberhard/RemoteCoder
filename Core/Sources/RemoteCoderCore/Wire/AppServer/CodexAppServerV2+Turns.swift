extension CodexAppServerV2 {
    enum CyberAccessProgram: String, Codable, Sendable, Hashable {
        case standard
        case daybreakBlue
        case daybreakRed
    }

    struct TurnStartParams: Encodable, Sendable {
        let threadId: String
        let input: [UserInput]
        let cwd: String?
        let approvalPolicy: String
        let sandboxPolicy: JSONValue
        let model: String
        let cyberAccessProgram: CyberAccessProgram?
        let effort: ReasoningEffort?
        let serviceTier: ServiceTierOverride?
        let additionalContext: [String: AdditionalContextEntry]?
        let clientUserMessageId: String
        let summary = DispatchPolicy.reasoningSummary
    }

    struct AdditionalContextEntry: Codable, Sendable, Hashable {
        let kind: AdditionalContextKind
        let value: String
    }

    enum AdditionalContextKind: String, Codable, Sendable, Hashable {
        case untrusted
        case application
    }

    struct TurnStartResponse: Codable, Sendable {
        let turn: Turn
    }

    struct TurnSteerParams: Encodable, Sendable {
        let threadId: String
        let input: [UserInput]
        let expectedTurnId: String
        let additionalContext: [String: AdditionalContextEntry]?
        let clientUserMessageId: String?
    }

    struct TurnSteerResponse: Codable, Sendable {
        let turnId: String
    }

    struct QueuedSubmission: Decodable, Sendable, Equatable {
        let id: String
        let clientUserMessageId: String
    }

    struct ThreadQueueAddParams: Encodable, Sendable {
        let threadId: String
        let input: [UserInput]
        let clientUserMessageId: String
    }

    struct ThreadQueueAddResponse: Decodable, Sendable {
        let queuedSubmission: QueuedSubmission
    }

    struct ThreadQueueListParams: Encodable, Sendable {
        let threadId: String
        let cursor: String?
    }

    struct ThreadQueueListResponse: Decodable, Sendable {
        let data: [QueuedSubmission]
        let nextCursor: String?
    }

    struct ThreadQueueItemParams: Encodable, Sendable {
        let threadId: String
        let queuedSubmissionId: String
    }

    struct ThreadQueueStartResponse: Decodable, Sendable {
        let turn: Turn
    }

    struct ThreadQueueDeleteResponse: Decodable, Sendable {
        let deleted: Bool
    }

    struct TurnInterruptParams: Encodable, Sendable {
        let threadId: String
        let turnId: String
    }

    struct TurnInterruptResponse: Codable, Sendable {}
}
