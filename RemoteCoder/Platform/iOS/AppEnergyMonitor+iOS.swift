import UIKit

extension AppEnergyMonitor {
    static func memoryWarningObservers(_ onWarning: @escaping @MainActor () -> Void) -> [any NSObjectProtocol] {
        [NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onWarning() }
        }]
    }
}
