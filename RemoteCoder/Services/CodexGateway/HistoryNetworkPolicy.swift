import Foundation
import Network

@MainActor
final class HistoryNetworkPolicy {
    private let monitor = NWPathMonitor()
    private(set) var allowsPrefetch = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor [weak self] in self?.allowsPrefetch = allowed }
        }
        monitor.start(queue: DispatchQueue(label: "RemoteCoder.history-network"))
    }

    deinit { monitor.cancel() }
}
