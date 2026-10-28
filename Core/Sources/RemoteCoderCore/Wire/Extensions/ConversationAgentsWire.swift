import Foundation

struct ConversationAgentsPage: Decodable, Sendable {
    let agents: [ConversationAgent]
    let revision: String
    let warnings: [String]
    var coverage: [ClusterCoverage]? = nil
}

struct ReportedProvider: RawRepresentable, Decodable, Sendable, Equatable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    var agentProvider: AgentProvider? { AgentProvider(rawValue: rawValue) }

    var displayName: String {
        agentProvider?.displayName ?? rawValue
    }
}

struct ConversationAgent: Decodable, Sendable, Identifiable, Equatable {
    struct Capabilities: Decodable, Sendable, Equatable {
        let inspect: Bool
        let openConversation: Bool
        let message: Bool
        let continueWork: Bool
        let stop: Bool
        let askParent: Bool
    }

    enum State: String, Decodable, Sendable {
        case working, waiting, completed, interrupted, failed, unknown, removed

        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    enum IntentState: String, Decodable, Sendable {
        case pending, admitted, abandoned, stopRequested = "stop_requested", unknown, removed

        init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let id: String
    let parentId: String?
    let ownerThreadId: String
    let threadId: String?
    let provider: ReportedProvider
    let source: String
    let title: String
    let model: String?
    let state: State
    let capabilities: Capabilities
    let executionId: String?
    let accountId: String?
    let lastActiveAt: Int64?
    var ownerHostId: UUID? = nil
    var jobId: String? = nil
    var parent: ClusterParent? = nil
    var intentState: IntentState? = nil
    var parentHostID: UUID? = nil
    var isStub: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case id, parentId, ownerThreadId, threadId, provider, source, title, model, state, capabilities
        case executionId, accountId, lastActiveAt, ownerHostId, jobId, parent, intentState, kind
        case parentHostID
    }

    var identity: String { ownerHostId.map { "\($0.uuidString)|\(jobId ?? id)" } ?? id }

    func address(localHostID: UUID) -> ConversationAddress? {
        threadId.map { .init(hostID: ownerHostId ?? localHostID, threadID: $0) }
    }
}

extension ConversationAgent {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decodeIfPresent(String.self, forKey: .kind)
        ownerHostId = try values.decodeIfPresent(UUID.self, forKey: .ownerHostId)
        jobId = try values.decodeIfPresent(String.self, forKey: .jobId)
        parent = try values.decodeIfPresent(ClusterParent.self, forKey: .parent)
        intentState = try values.decodeIfPresent(IntentState.self, forKey: .intentState)
        lastActiveAt = try values.decodeIfPresent(Int64.self, forKey: .lastActiveAt)
        if kind == "remote_intent" {
            ownerHostId = try values.decode(UUID.self, forKey: .ownerHostId)
            parent = try values.decode(ClusterParent.self, forKey: .parent)
            id = try values.decode(String.self, forKey: .jobId)
            ownerThreadId = parent?.threadId ?? ""
            parentId = nil
            threadId = nil
            provider = .init(rawValue: "unknown")
            source = kind ?? "remote_intent"
            title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Remote agent"
            model = nil
            state = intentState == .removed ? .removed : .unknown
            capabilities = .init(inspect: false, openConversation: false, message: false, continueWork: false, stop: false, askParent: false)
            executionId = nil
            accountId = nil
            isStub = true
        } else {
            isStub = false
            id = try values.decode(String.self, forKey: .id)
            parentId = try values.decodeIfPresent(String.self, forKey: .parentId)
            ownerThreadId = try values.decode(String.self, forKey: .ownerThreadId)
            threadId = try values.decodeIfPresent(String.self, forKey: .threadId)
            provider = try values.decode(ReportedProvider.self, forKey: .provider)
            source = try values.decode(String.self, forKey: .source)
            title = try values.decode(String.self, forKey: .title)
            model = try values.decodeIfPresent(String.self, forKey: .model)
            state = try values.decode(State.self, forKey: .state)
            capabilities = try values.decode(Capabilities.self, forKey: .capabilities)
            executionId = try values.decodeIfPresent(String.self, forKey: .executionId)
            accountId = try values.decodeIfPresent(String.self, forKey: .accountId)
        }
        parentHostID = try parent?.hostId ?? values.decodeIfPresent(UUID.self, forKey: .parentHostID)
    }
}

struct ConversationAgentOutput: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        struct Role: RawRepresentable, Decodable, Sendable, Equatable {
            let rawValue: String
            init(rawValue: String) { self.rawValue = rawValue }
            static let user = Self(rawValue: "user")

            init(from decoder: Decoder) throws {
                rawValue = try decoder.singleValueContainer().decode(String.self)
            }
        }

        let role: Role
        let text: String
    }
    let messages: [Message]
    let truncated: Bool
}
