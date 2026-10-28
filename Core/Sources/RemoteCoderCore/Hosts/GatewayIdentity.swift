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
