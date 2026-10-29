import Foundation

struct ClusterParent: Codable, Equatable, Sendable {
    let hostId: UUID
    let threadId: String

    var address: ConversationAddress { .init(hostID: hostId, threadID: threadId) }
    var json: JSONValue { .object(["hostId": .string(hostId.uuidString.lowercased()), "threadId": .string(threadId)]) }
}

struct ClusterReachability: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Sendable {
        case reachable, unreachable, unsupported, unknown

        init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let state: State
    let since: Date?
    let lastSeenAt: Date?

    private enum CodingKeys: String, CodingKey { case state, since, lastSeenAt }
}

struct ClusterMember: Decodable, Equatable, Sendable, Identifiable {
    let hostId: UUID
    let membership: UUID
    let name: String
    enum State: String, Decodable, Sendable {
        case active, removePending = "remove_pending", unknown

        init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let state: State
    let version: String?
    let load: ClusterLoad?
    let reachability: ClusterReachability
    let `protocol`: Int?

    var id: UUID { hostId }
}

struct ClusterLoad: Decodable, Equatable, Sendable {
    let cpuPercent: Double?
    enum MemoryPressure: String, Decodable, Sendable {
        case normal, warn, critical, unknown

        init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let memoryPressure: MemoryPressure?
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
        case ok, unreachable, unsupported, stale, unknown, refused, unavailable

        init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let hostId: UUID
    let name: String?
    let state: State
    var since: Date?
    var staleThrough: Date?

    var id: UUID { hostId }
    private enum CodingKeys: String, CodingKey { case hostId, name, state, since, staleThrough }
}

extension ClusterReachability {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(State.self, forKey: .state)
        since = try values.clusterDateIfPresent(forKey: .since)
        lastSeenAt = try values.clusterDateIfPresent(forKey: .lastSeenAt)
    }
}

extension ClusterCoverage {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hostId = try values.decode(UUID.self, forKey: .hostId)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        state = try values.decode(State.self, forKey: .state)
        since = try values.clusterDateIfPresent(forKey: .since)
        staleThrough = try values.clusterDateIfPresent(forKey: .staleThrough)
    }
}

private extension KeyedDecodingContainer {
    func clusterDateIfPresent(forKey key: Key) throws -> Date? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return try Date.ISO8601FormatStyle().parse(value)
    }
}

struct ClusterRemoval: Decodable, Sendable {
    let removed: Bool
    let pending: Bool
    let hostId: UUID
    let membership: UUID
}

protocol ClusterRemote: Actor {
    func clusterList() async throws -> ClusterList
    func clusterIssue(for host: UUID, name: String, membership: UUID) async throws -> ClusterIssuedCredential
    func clusterAccept(_ issued: ClusterIssuedCredential, name: String, membership: UUID) async throws
    func clusterRemove(host: UUID, membership: UUID) async throws -> ClusterRemoval
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

    func clusterRemove(host: UUID, membership: UUID) async throws -> ClusterRemoval {
        try await callDecodable(method: "cluster/remove", params: .object([
            "protocol": .number(1), "host": .string(host.uuidString.lowercased()),
            "membership": .string(membership.uuidString.lowercased())]), timeout: .seconds(10))
    }

    func setAgentParent(agent: ClusterParent, parent: ClusterParent?) async throws {
        let _: JSONValue = try await callDecodable(method: "agent/parent/set", params: .object([
            "protocol": .number(1), "agent": agent.json, "parent": parent?.json ?? .null]), timeout: .seconds(10))
    }
}

enum ClusterReadFailure: LocalizedError, Equatable {
    case deadline, unsupported

    var errorDescription: String? {
        switch self {
        case .deadline: "The cluster refresh deadline elapsed before this host answered."
        case .unsupported: "This gateway does not support cluster agent reads."
        }
    }
}

enum ClusterErrorClass: String, Decodable, Sendable {
    case usage, notFound = "not_found", refused, unavailable, uncertain, unsupported, conflict, unknown

    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

extension ClusterCoverage.State {
    static func failure(_ error: any Error) -> Self {
        if let error = error as? ClusterReadFailure {
            return error == .unsupported ? .unsupported : .unavailable
        }
        if let failure = error as? GatewayRPCFailure, case .cluster(let errorClass) = failure.kind {
            switch errorClass {
            case .unsupported: return .unsupported
            case .refused: return .refused
            case .unavailable: return .unavailable
            default: return .stale
            }
        }
        if error is URLError { return .unreachable }
        if let error = error as? GatewayClient.ClientError {
            switch error {
            case .serverError(_, let code) where code == -32601: return .unsupported
            case .notConnected, .connectionClosed, .connectionFailed, .gatewayRestarting, .gatewayNotReady, .requestTimedOut: return .unreachable
            default: break
            }
        }
        return .stale
    }
}
