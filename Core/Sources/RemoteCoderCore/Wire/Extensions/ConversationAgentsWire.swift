import Foundation

struct ConversationAgentsPage: Decodable, Sendable {
    let agents: [ConversationAgent]
    let revision: String
    let warnings: [String]
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
        case working, waiting, completed, interrupted, failed, unknown

        init(from decoder: Decoder) throws {
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
