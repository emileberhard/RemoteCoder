import Foundation

struct ConversationAgentRelation: Codable, Sendable, Equatable {
    var parentHostID: UUID? = nil
    let parentThreadId: String
    let parentAccountId: String?
    let agentId: String

    func parentAddress(localHostID: UUID) -> ConversationAddress {
        .init(hostID: parentHostID ?? localHostID, threadID: parentThreadId)
    }
}
