import Foundation

struct ConversationAgentsHost: Sendable {
    let id: UUID
    let name: String
    let gateway: GatewayClient
    let supportsCrossHost: Bool

    @concurrent func read(parent: ClusterParent) async throws -> ConversationAgentsPage {
        let page = try await gateway.conversationAgents(parent: parent, crossHost: supportsCrossHost)
        return .init(agents: Array(page.agents.prefix(512)), revision: page.revision,
                     warnings: page.warnings + (page.agents.count > 512 ? ["Agent list reached its limit"] : []), coverage: page.coverage)
    }
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

extension ConversationAgentsProjection {
    struct Snapshot: Sendable {
        let agents: [ConversationAgent]
        let sections: ConversationAgentSections
        let warnings: [String]
        let coverage: [ClusterCoverage]
        let coverageByHost: [UUID: ClusterCoverage]
        let agentsByID: [String: ConversationAgent]
    }

    @concurrent static func prepare(rowsByHost: [UUID: [ConversationAgent]], warningsByHost: [UUID: [String]],
                                    coverage: [UUID: ClusterCoverage], hostOrder: [UUID], activeSince: Int64) async throws -> Snapshot {
        var coverage = coverage
        var order = hostOrder
        var rows: [ConversationAgent] = []
        var warnings: [String] = []
        var warningSet: Set<String> = []
        for host in hostOrder {
            try Task.checkCancellation()
            for warning in warningsByHost[host] ?? [] where warningSet.insert(warning).inserted { warnings.append(warning) }
            let source = rowsByHost[host] ?? []
            for value in source {
                var row = value
                row.ownerHostId = row.ownerHostId ?? host
                if let owner = row.ownerHostId, coverage[owner] == nil {
                    coverage[owner] = .init(hostId: owner, name: nil, state: .unknown)
                    order.append(owner)
                }
                rows.append(row)
            }
        }
        let unavailable = Set(rows.lazy.filter {
            $0.isStub == true && ($0.intentState == .unknown || $0.intentState == .removed)
                && $0.ownerHostId.flatMap { coverage[$0]?.state } != .ok
        }.map(\.identity))
        let agents = merge(rows.filter { $0.isStub == true || !unavailable.contains($0.identity) })
        var index: [String: ConversationAgent] = [:]
        for agent in agents {
            index[agent.identity] = agent
            if index[agent.id] == nil { index[agent.id] = agent }
        }
        return Snapshot(agents: agents, sections: .init(agents: agents, activeSince: activeSince), warnings: warnings,
                        coverage: order.compactMap { coverage[$0] }, coverageByHost: coverage, agentsByID: index)
    }
}
