import Foundation
import Observation

@Observable @MainActor
final class ClusterModel {
    struct Host: Identifiable, Sendable {
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
    private(set) var membersByID: [UUID: ClusterMember] = [:]
    private(set) var isRefreshing = false
    private(set) var running: Set<UUID> = []
    private(set) var persistenceFailure: String?
    private(set) var operationFailure: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let pairsKey = "cluster.pairs.v1"
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshInputs: [GatewayHostConfiguration] = []
    @ObservationIgnored private var memberIndex: [UUID: [UUID: ClusterMember]] = [:]

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

    deinit { refreshTask?.cancel() }

    func refresh(hosts: [Host]) async {
        let inputs = hosts.map(\.configuration)
        if let task = refreshTask, !task.isCancelled, inputs == refreshInputs { await task.value; return }
        refreshTask?.cancel()
        let ids = Set(hosts.map(\.id))
        listings = listings.filter { ids.contains($0.key) }
        failures = failures.filter { ids.contains($0.key) }
        memberIndex = memberIndex.filter { ids.contains($0.key) }
        pairs.removeAll { $0.complete && (!ids.contains($0.first) || !ids.contains($0.second)) }
        let generation = UUID()
        self.generation = generation
        refreshInputs = inputs
        isRefreshing = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation { self.isRefreshing = false; self.refreshTask = nil }
            }
            var answered: Set<UUID> = []
            await BoundedFanOut.run(hosts, limit: BoundedFanOut.hostLimit, deadline: .now + .seconds(10), skipping: { _ in false }) { host in
                let result: Result<PreparedList, Error>
                do { result = .success(try await Self.read(host)) }
                catch { result = .failure(error) }
                guard self.generation == generation, !Task.isCancelled else { return }
                answered.insert(host.id)
                switch result {
                case .success(let prepared) where prepared.list.local.hostId == host.id:
                    self.listings[host.id] = prepared.list
                    self.memberIndex[host.id] = prepared.members
                    self.failures[host.id] = nil
                case .success: self.failures[host.id] = ClusterFailure.identityChanged.localizedDescription
                case .failure(let error): self.failures[host.id] = error.localizedDescription
                }
            }
            guard self.generation == generation, !Task.isCancelled else { return }
            for host in hosts where !answered.contains(host.id) { self.failures[host.id] = ClusterReadFailure.deadline.localizedDescription }
            let members = await Self.prepareMembers(self.memberIndex)
            guard self.generation == generation, !Task.isCancelled else { return }
            self.membersByID = members
        }
        refreshTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private struct PreparedList: Sendable {
        let list: ClusterList
        let members: [UUID: ClusterMember]
    }

    @concurrent private static func read(_ host: Host) async throws -> PreparedList {
        let list = try await host.remote.clusterList()
        return .init(list: list, members: Dictionary(list.members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    @concurrent private static func prepareMembers(_ lists: [UUID: [UUID: ClusterMember]]) async -> [UUID: ClusterMember] {
        var members: [UUID: ClusterMember] = [:]
        for list in lists.values {
            guard !Task.isCancelled else { return members }
            for (id, member) in list where members[id] == nil { members[id] = member }
        }
        return members
    }

    func isMember(_ host: UUID, of anchor: UUID) -> Bool {
        host == anchor || memberIndex[anchor]?[host]?.state == .active
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
        var edges: [UUID: Pair] = [:]
        for (owner, listing) in listings {
            for member in listing.members where owner == hostID || member.id == hostID {
                guard owner != member.id else { continue }
                edges[member.membership] = Pair(first: owner, second: member.id, membership: member.membership, operation: .remove)
            }
        }
        for edge in edges.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let existing = pairs.first { $0.membership == edge.membership }
            if existing == nil, !reservePair() { return }
            var pair = existing ?? edge
            if pair.operation != .remove {
                pair.operation = .remove
                pair.firstComplete = false
                pair.secondComplete = false
                pair.error = nil
            }
            replace(pair)
        }
        for id in edges.keys { await retry(id, hosts: hosts) }
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
                        pair.firstComplete = try await remove(from: first, peer: pair.second, membership: pair.membership)
                        if !pair.firstComplete { errors.append("Removal is pending on \(first.configuration.displayName). Retry.") }
                        replace(pair)
                    } catch { errors.append(error.localizedDescription) }
                }
                if !pair.secondComplete {
                    do {
                        let second = try operatorHost(pair.second, hosts: hosts)
                        pair.secondComplete = try await remove(from: second, peer: pair.first, membership: pair.membership)
                        if !pair.secondComplete { errors.append("Removal is pending on \(second.configuration.displayName). Retry.") }
                    } catch { errors.append(error.localizedDescription) }
                }
                pair.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
            }
            if pair.complete { pair.error = nil }
        } catch { pair.error = error.localizedDescription }
        replace(pair)
    }

    private func remove(from host: Host, peer: UUID, membership: UUID) async throws -> Bool {
        let receipt = try await host.remote.clusterRemove(host: peer, membership: membership)
        guard receipt.hostId == peer, receipt.membership == membership, receipt.removed else { throw ClusterFailure.identityChanged }
        return !receipt.pending
    }

    private func operatorHost(_ id: UUID, hosts: [Host]) throws -> Host {
        let name = membersByID[id]?.name ?? id.uuidString
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
