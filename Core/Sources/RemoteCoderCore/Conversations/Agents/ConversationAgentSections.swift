import Foundation

extension ConversationAgent {
    func isRecent(activeSince cutoff: Int64) -> Bool {
        switch state {
        case .working, .waiting: true
        case .completed, .interrupted, .failed, .unknown: lastActiveAt.map { $0 >= cutoff } ?? false
        }
    }
}

struct ConversationAgentRow: Identifiable, Equatable, Sendable {
    let agent: ConversationAgent
    let depth: Int
    var id: String { agent.id }
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
        let parents = Dictionary(agents.map { ($0.id, $0.parentId) }, uniquingKeysWith: { first, _ in first })
        var recentIDs = Set<String>()
        for agent in agents where agent.isRecent(activeSince: cutoff) {
            var id: String? = agent.id
            while let current = id, recentIDs.insert(current).inserted { id = parents[current] ?? nil }
        }
        recent = Self.rows(for: agents.filter { recentIDs.contains($0.id) })
        earlier = Self.rows(for: agents.filter { !recentIDs.contains($0.id) })
    }

    private static func rows(for agents: [ConversationAgent]) -> [ConversationAgentRow] {
        var result: [ConversationAgentRow] = []
        var visited = Set<String>()
        let ids = Set(agents.map(\.id))
        let children = Dictionary(grouping: agents, by: { $0.parentId ?? "" })
        func append(_ agent: ConversationAgent, depth: Int) {
            guard visited.insert(agent.id).inserted else { return }
            result.append(ConversationAgentRow(agent: agent, depth: min(depth, 4)))
            for child in children[agent.id] ?? [] { append(child, depth: depth + 1) }
        }
        for agent in agents where agent.parentId.map({ !ids.contains($0) }) ?? true { append(agent, depth: 0) }
        for agent in agents where !visited.contains(agent.id) { append(agent, depth: 0) }
        return result
    }
}

struct ConversationAgentSummary: Equatable, Sendable {
    let total: Int
    let recent: Int
}
