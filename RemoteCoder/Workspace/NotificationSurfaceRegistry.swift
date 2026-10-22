import Foundation
import Observation

@MainActor
@Observable
final class NotificationSurfaceRegistry {
    private var order: [UUID] = []
    @ObservationIgnored private var dismissers: [UUID: @MainActor () async -> Bool] = [:]

    var keySurfaceID: UUID? { order.last }

    func register(id: UUID, dismissCover: @escaping @MainActor () async -> Bool) {
        dismissers[id] = dismissCover
        markKey(id)
    }

    func markKey(_ id: UUID) {
        guard dismissers[id] != nil else { return }
        order.removeAll { $0 == id }
        order.append(id)
    }

    func unregister(id: UUID) {
        dismissers[id] = nil
        order.removeAll { $0 == id }
    }

    func dismissCoverOnKeySurface() async -> Bool {
        guard let id = keySurfaceID, let dismiss = dismissers[id] else { return true }
        return await dismiss()
    }
}
