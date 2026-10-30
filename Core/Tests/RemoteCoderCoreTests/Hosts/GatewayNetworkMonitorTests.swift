import Foundation
import Testing
@testable import RemoteCoderCore

struct GatewayNetworkMonitorTests {
    @Test func aStreamTerminatedBeforeRegistrationDoesNotRetainASubscriber() async {
        let monitor = GatewayNetworkMonitor()
        let (stream, updates) = AsyncStream.makeStream(of: GatewayNetworkPath.self, bufferingPolicy: .bufferingNewest(1))
        let subscription = GatewayNetworkSubscription(updates, onTermination: { _ in })
        updates.finish()

        func registerAndCount(on monitor: isolated GatewayNetworkMonitor) -> Int {
            monitor.observe(subscription)
            return monitor.subscribers.count
        }

        let count = await registerAndCount(on: monitor)
        #expect(count == 0)
        withExtendedLifetime(stream) {}
    }
}
