import Foundation

struct ConversationAgentRoster: Equatable, Sendable {
    let active: [ConversationAgent]
    let done: [ConversationAgent]

    static let empty = ConversationAgentRoster(active: [], done: [])

    var count: Int { active.count + done.count }
    var isWorking: Bool { active.contains { $0.state == .working } }

    private init(active: [ConversationAgent], done: [ConversationAgent]) {
        self.active = active
        self.done = done
    }

    init(agents: [ConversationAgent]) {
        let identities = Set(agents.map(\.identity))
        let addresses = Dictionary(agents.compactMap { agent -> (ConversationAddress, String)? in
            guard let host = agent.ownerHostId, let address = agent.address(localHostID: host) else { return nil }
            return (address, agent.identity)
        }, uniquingKeysWith: { first, _ in first })
        let direct = agents.enumerated().filter { _, agent in
            let tagged = agent.parent.flatMap { addresses[$0.address] }
            let legacy = agent.parentId.map { parent in agent.ownerHostId.map { "\($0.uuidString)|\(parent)" } ?? parent }
            return (tagged ?? legacy).map { $0 == agent.identity || !identities.contains($0) } ?? true
        }
        let newestFirst = direct.sorted { lhs, rhs in
            let left = lhs.element.lastActiveAt ?? .min, right = rhs.element.lastActiveAt ?? .min
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
        active = newestFirst.filter { [.working, .waiting, .unknown].contains($0.state) }
        done = newestFirst.filter { [.completed, .interrupted, .failed].contains($0.state) }
    }
}
