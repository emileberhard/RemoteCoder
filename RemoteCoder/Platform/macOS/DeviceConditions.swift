import Observation

@MainActor
@Observable
final class DeviceConditions {
    let batteryPercent: Int? = nil
    let charging: Bool? = nil
    let brightnessPercent: Int? = nil

    func start() {}

    func stop() {}
}
