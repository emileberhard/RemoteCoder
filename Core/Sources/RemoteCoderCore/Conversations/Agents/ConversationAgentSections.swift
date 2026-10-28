import Foundation

extension ConversationAgent {
    func isRecent(activeSince cutoff: Int64) -> Bool {
        switch state {
        case .working, .waiting: true
        case .completed, .interrupted, .failed, .unknown, .removed: lastActiveAt.map { $0 >= cutoff } ?? false
        }
    }
}

struct ConversationAgentRow: Identifiable, Equatable, Sendable {
    let agent: ConversationAgent
    let depth: Int
    var id: String { agent.identity }
}

struct ConversationAgentSections: Equatable, Sendable {
    let recent: [ConversationAgentRow]
    let earlier: [ConversationAgentRow]

    static let empty = ConversationAgentSections(recent: [], earlier: [])

    private init(recent: [ConversationAgentRow], earlier: [ConversationAgentRow]) {
        self.recent = recent
        self.earlier = earlier
    }

    init(agents: [ConversationAgent], activeSince cutoff: Int64) {
        let addresses = Dictionary(agents.compactMap { agent -> (ConversationAddress, String)? in
            guard let host = agent.ownerHostId, let address = agent.address(localHostID: host) else { return nil }
            return (address, agent.identity)
        }, uniquingKeysWith: { first, _ in first })
        let parents = Dictionary(agents.map { agent in
            let tagged = agent.parent.flatMap { addresses[$0.address] }
            let legacy = agent.parentId.map { parent in agent.ownerHostId.map { "\($0.uuidString)|\(parent)" } ?? parent }
            return (agent.identity, tagged ?? legacy)
        }, uniquingKeysWith: { first, _ in first })
        var recentIDs = Set<String>()
        for agent in agents where agent.isRecent(activeSince: cutoff) {
            var id: String? = agent.identity
            while let current = id, recentIDs.insert(current).inserted { id = parents[current] ?? nil }
        }
        recent = Self.rows(for: agents.filter { recentIDs.contains($0.identity) }, parents: parents)
        earlier = Self.rows(for: agents.filter { !recentIDs.contains($0.identity) }, parents: parents)
    }

    private static func rows(for agents: [ConversationAgent], parents: [String: String?]) -> [ConversationAgentRow] {
        var result: [ConversationAgentRow] = []
        var visited = Set<String>()
        let ids = Set(agents.map(\.identity))
        let children = Dictionary(grouping: agents, by: { (parents[$0.identity] ?? nil) ?? "" })
        func append(_ agent: ConversationAgent, depth: Int) {
            guard visited.insert(agent.identity).inserted else { return }
            result.append(ConversationAgentRow(agent: agent, depth: min(depth, 4)))
            for child in children[agent.identity] ?? [] { append(child, depth: depth + 1) }
        }
        for agent in agents where (parents[agent.identity] ?? nil).map({ !ids.contains($0) }) ?? true { append(agent, depth: 0) }
        for agent in agents where !visited.contains(agent.identity) { append(agent, depth: 0) }
        return result
    }
}

struct ConversationAgentSummary: Equatable, Sendable {
    let total: Int
    let recent: Int
}
