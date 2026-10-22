import Foundation

/// Optional work adapts to system pressure; calls, recording, live events and
/// direct manipulation retain their normal behavior.
struct AppEnergyPolicy: Equatable, Sendable {
    let isLowPowerModeEnabled: Bool
    let thermalState: ProcessInfo.ThermalState

    static var current: Self {
        let process = ProcessInfo.processInfo
        return Self(isLowPowerModeEnabled: process.isLowPowerModeEnabled,
                    thermalState: process.thermalState)
    }

    var conservesEnergy: Bool {
        isLowPowerModeEnabled || thermalState == .serious || thermalState == .critical
    }

    var waveformInterval: Duration { conservesEnergy ? .milliseconds(50) : .milliseconds(25) }

    func animatesDecorations(sceneActive: Bool, visible: Bool, reduceMotion: Bool) -> Bool {
        sceneActive && visible && !reduceMotion && !conservesEnergy
    }
}
