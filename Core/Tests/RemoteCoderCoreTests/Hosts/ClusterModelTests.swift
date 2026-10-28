import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct ClusterModelTests {
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

    @Test func installationCredentialsCannotJoin() async throws {
        let suite = "ClusterModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        let left = MemberRemote(host: first), right = MemberRemote(host: second)
        let model = ClusterModel(defaults: defaults)
        await model.refresh(hosts: [host(first, remote: left), host(second, remote: right)])
        var installation = host(first, remote: left).configuration
        installation.authToken = "rc1.installation"
        await model.join(second, anchor: first, hosts: [.init(configuration: installation, remote: left), host(second, remote: right)])
        #expect(model.pairs.isEmpty)
        #expect(await left.issued.isEmpty)
        #expect(await right.issued.isEmpty)
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

    init(host: UUID) { self.host = host }
    func setAcceptFailure(_ value: Bool) { acceptFailure = value }
    func setRemoveFailure(_ value: Bool) { removeFailure = value }

    func clusterList() -> ClusterList {
        .init(local: .init(hostId: host, name: "Fixture", incarnation: UUID(), version: "1.0.0", protocol: 1), members: members)
    }
    func clusterIssue(for host: UUID, name: String, membership: UUID) -> ClusterIssuedCredential {
        issued.append(membership)
        return .init(protocol: 1, host: self.host, incarnation: UUID(), membership: membership, pin: "fixture-pin", routes: [], credential: "fixture-credential")
    }
    func clusterAccept(_ issued: ClusterIssuedCredential, name: String, membership: UUID) throws {
        if acceptFailure { throw URLError(.cannotConnectToHost) }
        accepted.append(membership)
        members = [.init(hostId: issued.host, membership: membership, name: name, state: "active", version: "1.0.0", load: nil,
                         reachability: .init(state: "reachable", since: nil, lastSeenAt: nil), protocol: 1)]
    }
    func clusterRemove(host: UUID, membership: UUID) throws {
        if removeFailure { throw URLError(.cannotConnectToHost) }
        removed.append(membership)
        members.removeAll { $0.hostId == host && $0.membership == membership }
    }
    func setAgentParent(agent: ClusterParent, parent: ClusterParent?) {}
}
