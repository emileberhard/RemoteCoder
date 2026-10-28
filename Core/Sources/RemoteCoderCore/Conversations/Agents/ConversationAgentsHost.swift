import Foundation

struct ConversationAgentsHost: Sendable {
    let id: UUID
    let name: String
    let gateway: GatewayClient
    let supportsCrossHost: Bool
}

struct ConversationAgentsProjection {
    static func merge(_ agents: [ConversationAgent]) -> [ConversationAgent] {
        var rows: [String: ConversationAgent] = [:]
        var order: [String] = []
        for agent in agents {
            if rows[agent.identity] == nil { order.append(agent.identity) }
            if rows[agent.identity] == nil || rows[agent.identity]?.isStub == true || agent.isStub != true { rows[agent.identity] = agent }
        }
        return order.compactMap { rows[$0] }
    }
}
