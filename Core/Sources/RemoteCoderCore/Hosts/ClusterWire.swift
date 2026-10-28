import Foundation

struct ClusterParent: Codable, Equatable, Sendable {
    let hostId: UUID
    let threadId: String

    var address: ConversationAddress { .init(hostID: hostId, threadID: threadId) }
    var json: JSONValue { .object(["hostId": .string(hostId.uuidString.lowercased()), "threadId": .string(threadId)]) }
}

struct ClusterReachability: Decodable, Equatable, Sendable {
    let state: String
    let since: String?
    let lastSeenAt: String?
}

struct ClusterMember: Decodable, Equatable, Sendable, Identifiable {
    let hostId: UUID
    let membership: UUID
    let name: String
    let state: String
    let version: String?
    let load: ClusterLoad?
    let reachability: ClusterReachability
    let `protocol`: Int?

    var id: UUID { hostId }
}

struct ClusterLoad: Decodable, Equatable, Sendable {
    let cpuPercent: Double?
    let memoryPressure: String?
    let activeAgents: Int?
}

struct ClusterList: Decodable, Sendable {
    struct LocalHost: Decodable, Sendable {
        let hostId: UUID
        let name: String
        let incarnation: UUID
        let version: String
        let `protocol`: Int
    }
    let local: LocalHost
    let members: [ClusterMember]
    private enum CodingKeys: String, CodingKey { case local = "self", members }
}

struct ClusterIssuedCredential: Decodable, Sendable {
    let `protocol`: Int
    let host: UUID
    let incarnation: UUID
    let membership: UUID
    let pin: String
    let routes: [String]
    let credential: String
}

struct ClusterCoverage: Decodable, Equatable, Sendable, Identifiable {
    enum State: String, Decodable, Sendable {
        case ok, unreachable, unsupported, stale, unknown, removed, refused
    }

    let hostId: UUID
    let name: String?
    let state: State
    var since: String?
    var staleThrough: String?

    var id: UUID { hostId }
}

protocol ClusterRemote: Actor {
    func clusterList() async throws -> ClusterList
    func clusterIssue(for host: UUID, name: String, membership: UUID) async throws -> ClusterIssuedCredential
    func clusterAccept(_ issued: ClusterIssuedCredential, name: String, membership: UUID) async throws
    func clusterRemove(host: UUID, membership: UUID) async throws
    func setAgentParent(agent: ClusterParent, parent: ClusterParent?) async throws
}

extension GatewayClient: ClusterRemote {
    func clusterList() async throws -> ClusterList {
        try await callDecodable(method: "cluster/list", params: .object(["protocol": .number(1)]), timeout: .seconds(10))
    }

    func clusterIssue(for host: UUID, name: String, membership: UUID) async throws -> ClusterIssuedCredential {
        try await callDecodable(method: "cluster/issue", params: .object([
            "protocol": .number(1), "for": .string(host.uuidString.lowercased()), "name": .string(name),
            "membership": .string(membership.uuidString.lowercased())]), timeout: .seconds(10))
    }

    func clusterAccept(_ issued: ClusterIssuedCredential, name: String, membership: UUID) async throws {
        let _: JSONValue = try await callDecodable(method: "cluster/accept", params: .object([
            "protocol": .number(1), "host": .string(issued.host.uuidString.lowercased()), "name": .string(name),
            "membership": .string(membership.uuidString.lowercased()), "pin": .string(issued.pin),
            "routes": .array(issued.routes.map(JSONValue.string)), "credential": .string(issued.credential)]), timeout: .seconds(10))
    }

    func clusterRemove(host: UUID, membership: UUID) async throws {
        let _: JSONValue = try await callDecodable(method: "cluster/remove", params: .object([
            "protocol": .number(1), "host": .string(host.uuidString.lowercased()),
            "membership": .string(membership.uuidString.lowercased())]), timeout: .seconds(10))
    }

    func setAgentParent(agent: ClusterParent, parent: ClusterParent?) async throws {
        let _: JSONValue = try await callDecodable(method: "agent/parent/set", params: .object([
            "protocol": .number(1), "agent": agent.json, "parent": parent?.json ?? .null]), timeout: .seconds(10))
    }
}
