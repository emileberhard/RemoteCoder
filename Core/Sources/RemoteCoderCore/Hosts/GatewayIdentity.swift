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
        let probes = Task {
            await BoundedFanOut.run(unresolved, limit: 3, skipping: { _ in false }) { host in
                do {
                    let identity = try await read(host)
                    try Task.checkCancellation()
                    resolved.append((host, identity))
                } catch {}
            }
        }
        let timeout = Task {
            do {
                try await Task.sleep(for: budget)
                probes.cancel()
            } catch {}
        }
        await withTaskCancellationHandler {
            await probes.value
        } onCancel: {
            probes.cancel()
            timeout.cancel()
        }
        timeout.cancel()
        await timeout.value
        return resolved
    }
}
