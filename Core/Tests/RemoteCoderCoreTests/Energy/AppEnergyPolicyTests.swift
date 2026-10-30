import Foundation
import Testing
@testable import RemoteCoderCore

struct AppEnergyPolicyTests {
    @Test(arguments: [
        (false, ProcessInfo.ThermalState.nominal, false), (false, .fair, false), (false, .serious, true),
        (false, .critical, true), (true, .nominal, true), (true, .fair, true),
    ])
    func powerAndThermalPressureLimitOnlyOptionalWork(lowPower: Bool, thermal: ProcessInfo.ThermalState, constrained: Bool) {
        let policy = AppEnergyPolicy(isLowPowerModeEnabled: lowPower, thermalState: thermal)
        #expect(policy.conservesEnergy == constrained)
        #expect(policy.animatesDecorations(sceneActive: true, visible: true, reduceMotion: false) == !constrained)
    }

    @Test(arguments: [false, true], [false, true])
    func inactiveAndOffscreenContentHasNoDecorativeClock(active: Bool, visible: Bool) {
        let policy = AppEnergyPolicy(isLowPowerModeEnabled: false, thermalState: .nominal)
        #expect(policy.animatesDecorations(sceneActive: active, visible: visible, reduceMotion: false) == (active && visible))
        #expect(!policy.animatesDecorations(sceneActive: active, visible: visible, reduceMotion: true))
    }
}
