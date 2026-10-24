import Observation
import UIKit

@MainActor
@Observable
final class DeviceConditions {
    private(set) var batteryPercent: Int?
    private(set) var charging: Bool?
    private(set) var brightnessPercent: Int?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readBattery() }
            })
        }
        observers.append(center.addObserver(forName: UIScreen.brightnessDidChangeNotification, object: nil,
                                            queue: .main) { [weak self] notification in
            let brightness = (notification.object as? UIScreen)?.brightness
            MainActor.assumeIsolated { self?.setBrightness(brightness) }
        })
        readBattery()
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        setBrightness(screen?.brightness)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func readBattery() {
        let device = UIDevice.current
        let level = device.batteryLevel
        let percent = level >= 0 ? Int((level * 100).rounded()) : nil
        let state: Bool? = switch device.batteryState {
        case .charging, .full: true
        case .unplugged: false
        case .unknown: nil
        @unknown default: nil
        }
        if percent != batteryPercent { batteryPercent = percent }
        if state != charging { charging = state }
    }

    private func setBrightness(_ brightness: CGFloat?) {
        let bucket = brightness.map { Int(($0 * 10).rounded()) * 10 }
        if bucket != brightnessPercent { brightnessPercent = bucket }
    }
}
