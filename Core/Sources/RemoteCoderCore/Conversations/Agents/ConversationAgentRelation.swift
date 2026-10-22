import Foundation

struct ConversationAgentRelation: Codable, Sendable, Equatable {
    let parentThreadId: String
    let parentAccountId: String?
    let agentId: String
}
