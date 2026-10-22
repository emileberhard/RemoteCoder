#if os(macOS)
import Foundation

extension AppEnergyMonitor {
    static func memoryWarningObservers(_ onWarning: @escaping @MainActor () -> Void) -> [any NSObjectProtocol] {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { onWarning() }
        }
        source.activate()
        return [source]
    }
}
#endif
