import Foundation

struct GatewayIdentity: Decodable, Equatable, Sendable {
    let hostId: UUID
    let incarnation: UUID
}

extension HostStore {
    func canonicalHostID(_ id: UUID) -> UUID {
        hosts.first { $0.id == id || $0.configuration.legacyIDs.contains(id) }?.id ?? id
    }
}

@MainActor
enum GatewayIdentityLaunch {
    static func read(hosts: [GatewayHostConfiguration], budget: Duration,
                     using read: @escaping @MainActor (GatewayHostConfiguration) async throws -> GatewayIdentity) async -> [(GatewayHostConfiguration, GatewayIdentity)] {
        let unresolved = hosts.filter { $0.gatewayID != $0.id }
        guard !unresolved.isEmpty else { return [] }
        var resolved: [(GatewayHostConfiguration, GatewayIdentity)] = []
        await BoundedFanOut.run(unresolved, limit: BoundedFanOut.hostLimit, deadline: .now + budget, skipping: { _ in false }) { host in
            do {
                let identity = try await read(host)
                try Task.checkCancellation()
                resolved.append((host, identity))
            } catch {}
        }
        return resolved
    }
}
