import Foundation

extension CodexAppServerV2 {
    struct Thread: Sendable {
        let id: String
        let preview: String
        var previewContent: ThreadPreview {
            switch AgentProvider.provider(forThreadID: id) {
            case .codex: .rawPrompt(preview)
            case .claude: .preparedDisplay(preview)
            }
        }
        var model: String? = nil
        var modelProvider: String? = nil
        var reasoningEffort: ReasoningEffort? = nil
        var extra: ThreadExtra? = nil
        let createdAt: Int64
        let updatedAt: Int64
        /// Sidebar recency, independent of the content revision. Claude supplies
        /// this in its header; the history service resolves Codex turn summaries.
        var lastTurnCompletedAt: Int64? = nil
        var sidebarTimestamp: Int64 { lastTurnCompletedAt ?? createdAt }
        var recencyAt: Int64? = nil
        let path: String?
        let cwd: String
        let source: JSONValue
        var name: String?
        let status: ThreadStatus
        var parentThreadId: String? = nil
        var canAcceptDirectInput: Bool? = nil
        var agentRelation: ConversationAgentRelation? = nil
    }

    enum ThreadPreview: Sendable {
        case rawPrompt(String)
        case preparedDisplay(String)

        var displayText: String {
            switch self {
            case .rawPrompt(let text): UserMessageText(text).preview
            case .preparedDisplay(let text): text
            }
        }
    }

    struct ThreadExtra: Codable, Equatable, Sendable {
        let serviceTier: String?
        private let hasServiceTier: Bool

        init(serviceTier: String?) {
            self.serviceTier = serviceTier
            hasServiceTier = true
        }

        var fastModeSelection: Bool? {
            hasServiceTier ? ServiceTier.fastModeSelection(for: serviceTier) : nil
        }

        private enum CodingKeys: String, CodingKey { case serviceTier }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasServiceTier = container.contains(.serviceTier)
            serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if hasServiceTier { try container.encode(serviceTier, forKey: .serviceTier) }
        }
    }

    struct Turn: Equatable, Sendable {
        let id: String
        let items: [ThreadItem]
        let startedAt: Int64?
        let completedAt: Int64?
        let status: TurnStatus
        let error: TurnError?
    }

    struct TurnError: Codable, Equatable, Sendable {
        let message: String
    }

    enum TurnStatus: String, Codable, Sendable {
        case completed
        case interrupted
        case failed
        case inProgress
    }

    enum ThreadStatus: Sendable, Hashable {
        case notLoaded
        case idle
        case active
        case systemError
        case unknown(String)
    }

    struct ThreadStartParams: Encodable, Sendable {
        let model: String
        let cwd: String?
        let approvalPolicy: String
        let sandbox: String
        let serviceName: String
        let serviceTier: ServiceTierOverride?
        let config: ThreadStartConfig?
        let persistExtendedHistory = true
    }

    struct ThreadStartConfig: Encodable, Sendable, Equatable {
        let modelReasoningEffort: ReasoningEffort
        let modelReasoningSummary = DispatchPolicy.reasoningSummary

        private enum CodingKeys: String, CodingKey {
            case modelReasoningEffort = "model_reasoning_effort"
            case modelReasoningSummary = "model_reasoning_summary"
        }
    }

    struct ThreadResumeParams: Encodable, Sendable {
        let threadId: String
        let model: String
        let cwd: String?
        let approvalPolicy: String
        let sandbox: String
        let serviceTier: ServiceTierOverride?
        let persistExtendedHistory = true
        let excludeTurns = true
    }

    struct ThreadForkParams: Encodable, Sendable {
        let threadId: String
        let lastTurnId: String?
        let serviceTier: ServiceTierOverride?
        let threadSource = "user"
        let persistExtendedHistory = true
        let excludeTurns = true
    }

    struct ThreadForkResponse: Codable, Sendable {
        let thread: Thread
        let model: String
        let modelProvider: String
        let cwd: String
        let reasoningEffort: ReasoningEffort?
    }

    struct ThreadListParams: Encodable, Sendable {
        let cursor: String?
        let limit: UInt32
        let useStateDbOnly: Bool
        let sortKey = "updated_at"
        let includeCompletionTimes = true
    }

    struct ThreadListResponse: Codable, Sendable {
        let data: [Thread]
        let nextCursor: String?
        var completionTimes: [String: Int64?]? = nil
    }

    struct ThreadReadParams: Encodable, Sendable {
        let threadId: String
        let includeTurns: Bool
    }

    struct ThreadReadResponse: Codable, Sendable {
        let thread: Thread
    }

    struct ThreadItemsListResponse: Codable, Sendable {
        struct Entry: Codable, Equatable, Sendable {
            let turnId: String
            let item: ThreadItem
            var startedAtOrdinal: Int64?
            var startedAtMs: Int64?
            var completedAtMs: Int64?
            var isComplete: Bool?
        }
        let data: [Entry]
        let nextCursor: String?
        let backwardsCursor: String?
    }

    struct ThreadTurnsListResponse: Codable, Sendable {
        let data: [Turn]
        let nextCursor: String?
        let backwardsCursor: String?
    }

    enum SortDirection: String, Codable, Sendable, Hashable {
        case asc
        case desc
    }

}

extension CodexAppServerV2.Thread: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case preview
        case model
        case modelProvider
        case reasoningEffort
        case extra
        case createdAt
        case updatedAt
        case lastTurnCompletedAt
        case recencyAt
        case path
        case cwd
        case source
        case name
        case status
        case parentThreadId, canAcceptDirectInput, agentRelation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.preview = try container.decode(String.self, forKey: .preview)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.modelProvider = try container.decodeIfPresent(String.self, forKey: .modelProvider)
        self.reasoningEffort = try container.decodeIfPresent(CodexAppServerV2.ReasoningEffort.self, forKey: .reasoningEffort)
        self.extra = try container.decodeIfPresent(CodexAppServerV2.ThreadExtra.self, forKey: .extra)
        self.createdAt = try container.decode(Int64.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
        self.lastTurnCompletedAt = try container.decodeIfPresent(Int64.self, forKey: .lastTurnCompletedAt)
        self.recencyAt = try container.decodeIfPresent(Int64.self, forKey: .recencyAt)
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.cwd = try container.decode(String.self, forKey: .cwd)
        self.source = try container.decode(JSONValue.self, forKey: .source)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.status = try container.decodeIfPresent(CodexAppServerV2.ThreadStatus.self, forKey: .status) ?? .notLoaded
        parentThreadId = try container.decodeIfPresent(String.self, forKey: .parentThreadId)
        canAcceptDirectInput = try container.decodeIfPresent(Bool.self, forKey: .canAcceptDirectInput)
        agentRelation = try container.decodeIfPresent(ConversationAgentRelation.self, forKey: .agentRelation)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(preview, forKey: .preview)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(modelProvider, forKey: .modelProvider)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(extra, forKey: .extra)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastTurnCompletedAt, forKey: .lastTurnCompletedAt)
        try container.encodeIfPresent(recencyAt, forKey: .recencyAt)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(parentThreadId, forKey: .parentThreadId)
        try container.encodeIfPresent(canAcceptDirectInput, forKey: .canAcceptDirectInput)
        try container.encodeIfPresent(agentRelation, forKey: .agentRelation)
    }
}

extension CodexAppServerV2.ThreadStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "notLoaded":
            self = .notLoaded
        case "idle":
            self = .idle
        case "active":
            self = .active
        case "systemError":
            self = .systemError
        default:
            self = .unknown(type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notLoaded:
            try container.encode("notLoaded", forKey: .type)
        case .idle:
            try container.encode("idle", forKey: .type)
        case .active:
            try container.encode("active", forKey: .type)
        case .systemError:
            try container.encode("systemError", forKey: .type)
        case .unknown(let raw):
            try container.encode(raw, forKey: .type)
        }
    }
}

extension CodexAppServerV2.Turn: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case items
        case startedAt
        case completedAt
        case status
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.items = try container.decodeIfPresent([CodexAppServerV2.ThreadItem].self, forKey: .items) ?? []
        self.startedAt = try container.decodeIfPresent(Int64.self, forKey: .startedAt)
        self.completedAt = try container.decodeIfPresent(Int64.self, forKey: .completedAt)
        self.status = try container.decode(CodexAppServerV2.TurnStatus.self, forKey: .status)
        self.error = try container.decodeIfPresent(CodexAppServerV2.TurnError.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

extension CodexAppServerV2.Turn: Identifiable {}

extension CodexAppServerV2.ThreadItemsListResponse.Entry: Identifiable {
    var id: String { item.id }
}

extension CodexAppServerV2 {
    struct ThreadObservationCheckpoint: Codable, Sendable {
        let turnsBackwardsCursor: String?
        let itemsBackwardsCursor: String?
        let activeTurn: Turn?
        let historyUnavailable: Bool
        let liveItems: [ThreadItemsListResponse.Entry]
    }

    enum ThreadSubscribeResponse: Decodable, Sendable {
        case notLoaded
        case subscribed(subscriptionID: String, thread: Thread, checkpoint: ThreadObservationCheckpoint)

        private enum CodingKeys: String, CodingKey { case status, subscriptionId, thread, checkpoint }
        private enum Status: String, Decodable { case notLoaded, subscribed }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(Status.self, forKey: .status) {
            case .notLoaded: self = .notLoaded
            case .subscribed:
                self = .subscribed(subscriptionID: try values.decode(String.self, forKey: .subscriptionId),
                    thread: try values.decode(Thread.self, forKey: .thread),
                    checkpoint: try values.decode(ThreadObservationCheckpoint.self, forKey: .checkpoint))
            }
        }
    }
}
