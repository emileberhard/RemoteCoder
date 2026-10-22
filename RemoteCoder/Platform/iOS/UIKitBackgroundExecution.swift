import UIKit

@MainActor
final class UIKitBackgroundExecution: BackgroundExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var graceTask: Task<Void, Never>?

    func hold(named name: String, onExpiration: @escaping @MainActor () -> Void) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            onExpiration()
        }
    }

    func holdWithGrace(named name: String, for grace: Duration, onExpiration: @escaping @MainActor () -> Void) {
        hold(named: name, onExpiration: onExpiration)
        guard graceTask == nil else { return }
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self?.graceTask = nil
            onExpiration()
        }
    }

    func release() {
        graceTask?.cancel()
        graceTask = nil
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
