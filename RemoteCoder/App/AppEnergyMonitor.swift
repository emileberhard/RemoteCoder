import Foundation
import Observation

@MainActor
@Observable
final class AppEnergyMonitor {
    private(set) var policy = AppEnergyPolicy.current
    @ObservationIgnored private let workspace: ChatWorkspaceModel
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(workspace: ChatWorkspaceModel) {
        self.workspace = workspace
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers += Self.memoryWarningObservers { [weak self] in self?.releaseReusableCaches() }
    }

    func refresh() {
        let current = AppEnergyPolicy.current
        if current != policy { policy = current }
        workspace.handleEnergyPolicyChanged(current)
    }

    private func releaseReusableCaches() {
        workspace.releaseReusableCaches()
        MermaidRenderer.shared.removeCachedDiagrams()
    }
}
