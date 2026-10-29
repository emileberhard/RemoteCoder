import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ClusterModelTests {
    @Test func overlappingRefreshesShareOneRead() async throws {
        let suite = "ClusterModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let remote = MemberRemote(host: id)
        await remote.holdLists()
        let hosts = [host(id, remote: remote)]
        let model = ClusterModel(defaults: defaults)
        let first = Task { await model.refresh(hosts: hosts) }
        #expect(await waitUntil { await remote.listCalls == 1 })
        var secondStarted = false
        let second = Task { secondStarted = true; await model.refresh(hosts: hosts) }
        while !secondStarted { await Task.yield() }
        await remote.releaseLists()
        await first.value
        await second.value
        #expect(await remote.listCalls == 1)
        #expect(!model.isRefreshing)
    }

    @Test func aLateReadCannotReplaceANewerGeneration() async throws {
        let suite = "ClusterModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), oldMember = UUID(), newMember = UUID()
        let old = MemberRemote(host: id), current = MemberRemote(host: id)
        await old.setMembers([member(oldMember, name: "Old")])
        await current.setMembers([member(newMember, name: "Current")])
        await old.holdLists()
        let model = ClusterModel(defaults: defaults)
        let first = Task { await model.refresh(hosts: [host(id, remote: old)]) }
        #expect(await waitUntil { await old.listCalls == 1 })
        var replacement = host(id, remote: current).configuration
        replacement.name = "Replacement"
        await model.refresh(hosts: [.init(configuration: replacement, remote: current)])
        await old.releaseLists()
        await first.value
        #expect(model.listings[id]?.members.map(\.id) == [newMember])
        #expect(model.membersByID[newMember] != nil)
        #expect(model.membersByID[oldMember] == nil)
        #expect(!model.isRefreshing)
    }

    @Test func partialJoinResumesTheSameMembershipAndRejoinUsesANewOne() async throws {
        let suite = "ClusterModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        let left = MemberRemote(host: first), right = MemberRemote(host: second)
        await right.setAcceptFailure(true)
        let hosts: [ClusterModel.Host] = [host(first, remote: left), host(second, remote: right)]
        let model = ClusterModel(defaults: defaults)
        await model.refresh(hosts: hosts)
        await model.join(second, anchor: first, hosts: hosts)
        let pending = try #require(model.pairs.first)
        #expect(pending.firstComplete && !pending.secondComplete)
        #expect(pending.error != nil)
        let restored = ClusterModel(defaults: defaults)
        await right.setAcceptFailure(false)
        await restored.retry(pending.id, hosts: hosts)
        #expect(restored.pairs.first?.complete == true)
        #expect(await left.accepted == [pending.membership])
        #expect(await right.accepted == [pending.membership])
        await restored.refresh(hosts: hosts)
        await right.setRemoveFailure(true)
        await restored.remove(second, hosts: hosts)
        let removal = try #require(restored.pairs.first)
        #expect(removal.operation == .remove)
        #expect(removal.firstComplete && !removal.secondComplete)
        #expect(await left.removed == [pending.membership])
        await right.setRemoveFailure(false)
        await restored.retry(removal.id, hosts: hosts)
        await restored.refresh(hosts: hosts)
        await restored.join(second, anchor: first, hosts: hosts)
        let rejoined = try #require(restored.pairs.last)
        #expect(rejoined.membership != pending.membership)
        #expect(rejoined.complete)
    }

    @Test func installationCredentialsJoin() async throws {
        let suite = "ClusterModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        let left = MemberRemote(host: first), right = MemberRemote(host: second)
        let hosts = [(first, left), (second, right)].map { id, remote in
            var configuration = host(id, remote: remote).configuration
            configuration.authToken = "rc1.\(id)"
            return ClusterModel.Host(configuration: configuration, remote: remote)
        }
        let model = ClusterModel(defaults: defaults)
        await model.refresh(hosts: hosts)
        await model.join(second, anchor: first, hosts: hosts)
        let pair = try #require(model.pairs.first)
        #expect(pair.complete)
        #expect(await left.accepted == [pair.membership])
        #expect(await right.accepted == [pair.membership])
    }

    @Test func missingMembersRemainVisibleAsPendingPairs() async throws {
        let suite = "ClusterModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID(), missing = UUID()
        let left = MemberRemote(host: first), right = MemberRemote(host: second)
        await left.setMembers([member(missing, name: "Missing")])
        let hosts = [host(first, remote: left), host(second, remote: right)]
        let model = ClusterModel(defaults: defaults)
        await model.refresh(hosts: hosts)
        await model.join(second, anchor: first, hosts: hosts)
        #expect(model.pairs.count == 2)
        #expect(model.pairs.first { $0.includes(first) }?.complete == true)
        #expect(model.pairs.first { $0.includes(missing) }?.error?.contains("Add Missing in Hosts") == true)
        let missingPair = try #require(model.pairs.first { $0.includes(missing) })
        let missingRemote = MemberRemote(host: missing)
        await model.retry(missingPair.id, hosts: hosts + [host(missing, remote: missingRemote)])
        #expect(model.pairs.first { $0.id == missingPair.id }?.complete == true)
        #expect(await missingRemote.accepted == [missingPair.membership])
    }

    @Test func removalJournalsUnconfiguredEdgesAndPendingAcknowledgements() async throws {
        let suite = "ClusterModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let anchor = UUID(), target = UUID(), missing = UUID()
        let left = MemberRemote(host: anchor), right = MemberRemote(host: target), third = MemberRemote(host: missing)
        let anchorEdge = member(anchor, name: "Anchor"), missingEdge = member(missing, name: "Missing")
        await right.setMembers([anchorEdge, missingEdge])
        await left.setRemovalPending(true)
        let hosts = [host(anchor, remote: left), host(target, remote: right)]
        let model = ClusterModel(defaults: defaults)
        await model.refresh(hosts: hosts)
        await model.remove(target, hosts: hosts)
        #expect(model.pairs.count == 2)
        let pending = try #require(model.pairs.first { $0.membership == anchorEdge.membership })
        #expect(!pending.complete)
        #expect(pending.error?.contains("pending") == true)
        let unconfigured = try #require(model.pairs.first { $0.membership == missingEdge.membership })
        #expect(!unconfigured.complete)
        #expect(unconfigured.error?.contains("Add Missing in Hosts") == true)
        let restored = ClusterModel(defaults: defaults)
        await left.setRemovalPending(false)
        await restored.retry(pending.id, hosts: hosts)
        await restored.retry(unconfigured.id, hosts: hosts + [host(missing, remote: third)])
        #expect(restored.pairs.allSatisfy { $0.complete })
        #expect(await left.removed == [anchorEdge.membership, anchorEdge.membership])
        #expect(await third.removed == [missingEdge.membership])
        #expect(await right.removed.count == 2)
    }

    @Test func futureStatesAndFractionalCoverageDatesDecodeWithoutLosingMeaning() throws {
        let hostID = UUID()
        let fields: [String: Any] = ["hostId": hostID.uuidString, "membership": UUID().uuidString, "name": "Newer",
            "state": "future", "reachability": ["state": "future", "since": "2026-10-28T10:00:00.123456789Z",
                "lastSeenAt": "2026-10-28T10:00:00Z"], "load": ["memoryPressure": "future"]]
        let member = try JSONDecoder().decode(ClusterMember.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(member.state == .unknown)
        #expect(member.reachability.state == .unknown)
        #expect(member.load?.memoryPressure == .unknown)
        let since = try #require(member.reachability.since)
        let lastSeen = try #require(member.reachability.lastSeenAt)
        #expect(abs(since.timeIntervalSince(lastSeen) - 0.123456789) < 0.000001)
        let coverage = try JSONDecoder().decode(ClusterCoverage.self, from: JSONSerialization.data(withJSONObject:
            ["hostId": hostID.uuidString, "state": "future", "since": "2026-10-28T10:00:00.123456789Z",
             "staleThrough": "2026-10-28T10:00:00Z"]))
        #expect(coverage.state == .unknown)
        #expect(coverage.since == since)
        #expect(coverage.staleThrough == lastSeen)
    }

    private func member(_ id: UUID, name: String) -> ClusterMember {
        .init(hostId: id, membership: UUID(), name: name, state: .active, version: nil, load: nil,
              reachability: .init(state: .reachable, since: nil, lastSeenAt: nil), protocol: 1)
    }

    private func host(_ id: UUID, remote: MemberRemote) -> ClusterModel.Host {
        var host = GatewayHostConfiguration(id: id, name: id.uuidString, hostname: "fixture.example", port: 443, authToken: "operator-fixture")
        host.gatewayID = id
        return .init(configuration: host, remote: remote)
    }
}

private actor MemberRemote: ClusterRemote {
    let host: UUID
    var accepted: [UUID] = []
    var issued: [UUID] = []
    var removed: [UUID] = []
    private var members: [ClusterMember] = []
    private var acceptFailure = false
    private var removeFailure = false
    private var removalPending = false
    private(set) var listCalls = 0
    private var held = false
    private var lists: [CheckedContinuation<ClusterList, Never>] = []

    init(host: UUID) { self.host = host }
    func setMembers(_ members: [ClusterMember]) { self.members = members }
    func setAcceptFailure(_ value: Bool) { acceptFailure = value }
    func setRemoveFailure(_ value: Bool) { removeFailure = value }
    func setRemovalPending(_ value: Bool) { removalPending = value }

    func holdLists() { held = true }
    func releaseLists() {
        held = false
        let pending = lists
        lists = []
        for continuation in pending { continuation.resume(returning: listing()) }
    }
    func clusterList() async -> ClusterList {
        listCalls += 1
        if held { return await withCheckedContinuation { lists.append($0) } }
        return listing()
    }
    private func listing() -> ClusterList {
        .init(local: .init(hostId: host, name: "Fixture", incarnation: UUID(), version: "1.0.0", protocol: 1), members: members)
    }
    func clusterIssue(for host: UUID, name: String, membership: UUID) -> ClusterIssuedCredential {
        issued.append(membership)
        return .init(protocol: 1, host: self.host, incarnation: UUID(), membership: membership, pin: "fixture-pin", routes: [], credential: "fixture-credential")
    }
    func clusterAccept(_ issued: ClusterIssuedCredential, name: String, membership: UUID) throws {
        if acceptFailure { throw URLError(.cannotConnectToHost) }
        accepted.append(membership)
        members.removeAll { $0.hostId == issued.host }
        members.append(.init(hostId: issued.host, membership: membership, name: name, state: .active, version: "1.0.0", load: nil,
                         reachability: .init(state: .reachable, since: nil, lastSeenAt: nil), protocol: 1))
    }
    func clusterRemove(host: UUID, membership: UUID) throws -> ClusterRemoval {
        if removeFailure { throw URLError(.cannotConnectToHost) }
        removed.append(membership)
        members.removeAll { $0.hostId == host && $0.membership == membership }
        return .init(removed: true, pending: removalPending, hostId: host, membership: membership)
    }
    func setAgentParent(agent: ClusterParent, parent: ClusterParent?) {}
}
