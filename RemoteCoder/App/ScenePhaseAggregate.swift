import SwiftUI

@MainActor
final class ScenePhaseAggregate {
    private var phases: [UUID: ScenePhase] = [:]
    private(set) var phase: ScenePhase = .background

    var isActive: Bool { phase == .active }

    func update(_ scenePhase: ScenePhase, scene: UUID) -> ScenePhase? {
        phases[scene] = scenePhase
        return recompute()
    }

    func remove(scene: UUID) -> ScenePhase? {
        guard phases.removeValue(forKey: scene) != nil, !phases.isEmpty else { return nil }
        return recompute()
    }

    private func recompute() -> ScenePhase? {
        let next: ScenePhase
        if phases.values.contains(.active) {
            next = .active
        } else if phases.values.allSatisfy({ $0 == .background }) {
            next = .background
        } else {
            next = .inactive
        }
        guard next != phase else { return nil }
        phase = next
        return next
    }
}
