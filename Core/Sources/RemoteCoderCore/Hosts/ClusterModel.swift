import Foundation
import Observation

@Observable @MainActor
final class ClusterModel {
    struct Host: Identifiable {
        let configuration: GatewayHostConfiguration
        let remote: any ClusterRemote
        var id: UUID { configuration.id }
    }

    struct Pair: Codable, Equatable, Identifiable {
        enum Operation: String, Codable { case join, remove }
        let first: UUID
        let second: UUID
        let membership: UUID
        var operation: Operation
        var firstComplete = false
        var secondComplete = false
        var error: String?
        var id: UUID { membership }
        var complete: Bool { firstComplete && secondComplete }
        func includes(_ host: UUID) -> Bool { first == host || second == host }
    }

    private(set) var listings: [UUID: ClusterList] = [:]
    private(set) var failures: [UUID: String] = [:]
    private(set) var pairs: [Pair]
    private(set) var isRefreshing = false
    private(set) var running: Set<UUID> = []
    private(set) var persistenceFailure: String?
    private(set) var operationFailure: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let pairsKey = "cluster.pairs.v1"
    @ObservationIgnored private var generation = UUID()

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.pairsKey) {
            do { pairs = try JSONDecoder().decode([Pair].self, from: data) }
            catch {
                pairs = []
                persistenceFailure = "Pending cluster operations could not be read: \(error.localizedDescription)"
            }
        } else { pairs = [] }
    }

    func refresh(hosts: [Host]) async {
        let ids = Set(hosts.map(\.id))
        listings = listings.filter { ids.contains($0.key) }
        failures = failures.filter { ids.contains($0.key) }
        pairs.removeAll { $0.complete && (!ids.contains($0.first) || !ids.contains($0.second)) }
        let generation = UUID()
        self.generation = generation
        isRefreshing = true
        await withTaskGroup(of: (UUID, Result<ClusterList, Error>).self) { group in
            for host in hosts {
                group.addTask {
                    do { return (host.id, .success(try await host.remote.clusterList())) }
                    catch { return (host.id, .failure(error)) }
                }
            }
            for await (host, result) in group {
                guard self.generation == generation, !Task.isCancelled else { continue }
                switch result {
                case .success(let list) where list.local.hostId == host:
                    listings[host] = list
                    failures[host] = nil
                case .success: failures[host] = ClusterFailure.identityChanged.localizedDescription
                case .failure(let error): failures[host] = error.localizedDescription
                }
            }
        }
        if self.generation == generation { isRefreshing = false }
    }

    func isMember(_ host: UUID, of anchor: UUID) -> Bool {
        host == anchor || listings[anchor]?.members.contains { $0.hostId == host && $0.state == .active } == true
    }

    func join(_ hostID: UUID, anchor: UUID, hosts: [Host]) async {
        guard persistenceFailure == nil else { return }
        let members = Set([anchor] + (listings[anchor]?.members.filter { $0.state == .active }.map(\.id) ?? []))
        for member in members.sorted(by: { $0.uuidString < $1.uuidString }) where member != hostID {
            guard !isMember(hostID, of: member) else { continue }
            let existing = pairs.first { $0.includes(hostID) && $0.includes(member) && $0.operation == .join && !$0.complete }
            let pair = existing ?? Pair(first: member, second: hostID, membership: UUID(), operation: .join)
            if existing == nil {
                guard reservePair() else { return }
                pairs.append(pair)
                save()
            }
            await retry(pair.id, hosts: hosts)
        }
        await refresh(hosts: hosts)
    }

    func remove(_ hostID: UUID, hosts: [Host]) async {
        guard persistenceFailure == nil else { return }
        for host in hosts where host.id != hostID {
            let member = listings[host.id]?.members.first { $0.hostId == hostID }
                ?? listings[hostID]?.members.first { $0.hostId == host.id }
            guard let member else { continue }
            let existing = pairs.first { $0.membership == member.membership }
            if existing == nil, !reservePair() { return }
            var pair = existing ?? Pair(first: host.id, second: hostID, membership: member.membership, operation: .remove)
            if pair.operation != .remove {
                pair.operation = .remove
                pair.firstComplete = false
                pair.secondComplete = false
                pair.error = nil
            }
            replace(pair)
            await retry(pair.id, hosts: hosts)
        }
        await refresh(hosts: hosts)
    }

    func retry(_ id: UUID, hosts: [Host]) async {
        guard persistenceFailure == nil, !running.contains(id), var pair = pairs.first(where: { $0.id == id }) else { return }
        running.insert(id)
        defer { running.remove(id) }
        do {
            switch pair.operation {
            case .join:
                let first = try operatorHost(pair.first, hosts: hosts)
                let second = try operatorHost(pair.second, hosts: hosts)
                let issuedFirst = try await first.remote.clusterIssue(for: second.id, name: second.configuration.displayName, membership: pair.membership)
                let issuedSecond = try await second.remote.clusterIssue(for: first.id, name: first.configuration.displayName, membership: pair.membership)
                guard issuedFirst.host == first.id, issuedSecond.host == second.id,
                      issuedFirst.membership == pair.membership, issuedSecond.membership == pair.membership,
                      issuedFirst.protocol == 1, issuedSecond.protocol == 1 else { throw ClusterFailure.identityChanged }
                if !pair.firstComplete {
                    try await first.remote.clusterAccept(issuedSecond, name: second.configuration.displayName, membership: pair.membership)
                    pair.firstComplete = true
                    replace(pair)
                }
                if !pair.secondComplete {
                    try await second.remote.clusterAccept(issuedFirst, name: first.configuration.displayName, membership: pair.membership)
                    pair.secondComplete = true
                }
            case .remove:
                var errors: [String] = []
                if !pair.firstComplete {
                    do {
                        let first = try operatorHost(pair.first, hosts: hosts)
                        try await first.remote.clusterRemove(host: pair.second, membership: pair.membership)
                        pair.firstComplete = true
                        replace(pair)
                    } catch { errors.append(error.localizedDescription) }
                }
                if !pair.secondComplete {
                    do {
                        let second = try operatorHost(pair.second, hosts: hosts)
                        try await second.remote.clusterRemove(host: pair.first, membership: pair.membership)
                        pair.secondComplete = true
                    } catch { errors.append(error.localizedDescription) }
                }
                pair.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
            }
            if pair.complete { pair.error = nil }
        } catch { pair.error = error.localizedDescription }
        replace(pair)
    }

    private func operatorHost(_ id: UUID, hosts: [Host]) throws -> Host {
        let name = listings.values.flatMap(\.members).first { $0.id == id }?.name ?? id.uuidString
        guard let host = hosts.first(where: { $0.id == id }) else { throw ClusterFailure.connectionRequired(name) }
        guard !host.configuration.usesInstallationCredential else { throw ClusterFailure.operatorRequired(host.configuration.displayName) }
        return host
    }

    private func replace(_ pair: Pair) {
        pairs.removeAll { $0.id == pair.id }
        pairs.removeAll { $0.complete && $0.includes(pair.first) && $0.includes(pair.second) }
        pairs.append(pair)
        save()
    }

    private func reservePair() -> Bool {
        if pairs.count >= 256 { pairs.removeAll { $0.complete } }
        guard pairs.count < 256 else {
            operationFailure = "Finish the 256 pending cluster operations before starting another."
            return false
        }
        operationFailure = nil
        return true
    }

    private func save() {
        do { defaults.set(try JSONEncoder().encode(pairs), forKey: Self.pairsKey) }
        catch { persistenceFailure = "Pending cluster operations could not be saved: \(error.localizedDescription)" }
    }

    enum ClusterFailure: LocalizedError {
        case identityChanged
        case operatorRequired(String), connectionRequired(String)
        var errorDescription: String? {
            switch self {
            case .identityChanged: "The gateway's verified identity changed. Reconnect before joining."
            case .operatorRequired(let name): "Connect to \(name) with an operator credential, then retry."
            case .connectionRequired(let name): "Add \(name) in Hosts with an operator credential, verify its identity, then retry."
            }
        }
    }
}
