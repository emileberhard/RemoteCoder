extension CodexAppServerV2 {
    struct ThreadNameUpdatedNotification: Codable, Sendable {
        let threadId: String
        let threadName: String?
    }

    struct ThreadSettingsUpdatedNotification: Decodable, Sendable {
        struct Settings: Decodable, Sendable {
            let model: String
            let effort: ReasoningEffort?
            let serviceTier: String?
            private let reportsServiceTier: Bool

            private enum CodingKeys: String, CodingKey { case model, effort, serviceTier }

            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                model = try values.decode(String.self, forKey: .model)
                effort = try values.decodeIfPresent(ReasoningEffort.self, forKey: .effort)
                serviceTier = try values.decodeIfPresent(String.self, forKey: .serviceTier)
                reportsServiceTier = values.contains(.serviceTier)
            }

            var fastModeSelection: Bool? {
                reportsServiceTier ? ServiceTier.fastModeSelection(for: serviceTier) : nil
            }
        }
        let threadId: String
        let threadSettings: Settings
    }

    struct ThreadTokenUsageUpdatedNotification: Codable, Sendable {
        let threadId: String
        let turnId: String
        let tokenUsage: ThreadTokenUsage
    }

    struct ThreadTokenUsage: Codable, Sendable {
        let total: TokenUsageBreakdown
        let last: TokenUsageBreakdown
        let modelContextWindow: Int64?
    }

    struct TokenUsageBreakdown: Codable, Sendable {
        let totalTokens: Int64
    }

    struct AgentMessageDeltaNotification: Codable, Sendable {
        let threadId: String
        let turnId: String
        let itemId: String
        let delta: String
    }

}
