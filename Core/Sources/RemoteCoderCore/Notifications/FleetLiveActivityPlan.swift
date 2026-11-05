import Foundation

enum FleetLiveActivityPlan {
    struct Restored: Equatable, Sendable {
        let id: String
        let coordinatorID: UUID?
        let isLive: Bool
    }

    struct Restoration: Equatable, Sendable {
        let adopted: String?
        let ended: [String]
    }

    static func restore(_ activities: [Restored], configured: Set<UUID>) -> Restoration {
        let adopted = activities.first {
            $0.isLive && $0.coordinatorID.map(configured.contains) == true
        }?.id
        return Restoration(adopted: adopted, ended: activities.map(\.id).filter { $0 != adopted })
    }

    static func coordinator(capable: [UUID], preferred: UUID?, excluding failed: UUID? = nil) -> UUID? {
        let candidates = capable.filter { $0 != failed }
        if let preferred, candidates.contains(preferred) { return preferred }
        return candidates.first
    }
}
