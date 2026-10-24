import Foundation
import Network
import Observation
import SwiftUI

@MainActor
final class TelemetryContext {
    private let workspace: ChatWorkspaceModel
    private let voiceCalls: VoiceCallCenter
    private let energy: AppEnergyMonitor
    private let scenes: ScenePhaseAggregate
    private let device = DeviceConditions()
    private let network = NetworkInterfaceState()
    private let sampler: ProcessResourceSampler?
    private var observation: Task<Void, Never>?

    init(workspace: ChatWorkspaceModel, voiceCalls: VoiceCallCenter, energy: AppEnergyMonitor,
         scenes: ScenePhaseAggregate, recorder: TelemetryBuffer) {
        self.workspace = workspace
        self.voiceCalls = voiceCalls
        self.energy = energy
        self.scenes = scenes
        sampler = PerfBuild.isDisabled("resourceSampler") ? nil : ProcessResourceSampler(recorder: recorder)
    }

    func start() {
        guard let sampler, observation == nil else { return }
        device.start()
        network.start()
        observation = Task { [weak self] in
            for await context in Observations({ @MainActor [weak self] in self?.current() }) {
                guard let context, !Task.isCancelled else { continue }
                sampler.update(context)
            }
        }
    }

    func sceneChanged() {
        sampler?.update(current())
    }

    func stop() {
        observation?.cancel()
        observation = nil
        device.stop()
        network.stop()
        sampler?.stop()
    }

    private func current() -> UsageContext {
        let window = workspace.keyWindow
        let screen = window.selectedScreen
        let policy = energy.policy
        return UsageContext(
            scene: Self.scene(scenes.phase),
            surface: window.isHistoryDrawerOpen ? .drawer : .chat,
            turnRunningVisible: screen.map { $0.runningTurn != nil },
            voiceCall: voiceCalls.call.isActive,
            thermal: Self.thermal(policy.thermalState),
            lowPower: policy.isLowPowerModeEnabled,
            batteryPercent: device.batteryPercent,
            charging: device.charging,
            brightnessPercent: device.brightnessPercent,
            network: network.interface,
            route: screen.map { Self.route($0.target.gatewayConnectivity) }
        )
    }

    private static func scene(_ phase: ScenePhase) -> UsageContext.Scene {
        switch phase {
        case .active: .active
        case .inactive: .inactive
        default: .background
        }
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> UsageContext.Thermal? {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: nil
        }
    }

    private static func route(_ connectivity: GatewayConnectivity) -> UsageContext.Route {
        switch connectivity {
        case .connected(.lan): .lan
        case .connected(.configured): .configured
        case .connected(.relay): .relay
        case .restarting: .restarting
        case .disconnected: .disconnected
        }
    }
}

@MainActor
@Observable
private final class NetworkInterfaceState {
    private(set) var interface: UsageContext.Network?
    @ObservationIgnored private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interface: UsageContext.Network = if path.status != .satisfied { .none }
                else if path.usesInterfaceType(.wifi) { .wifi }
                else if path.usesInterfaceType(.cellular) { .cellular }
                else if path.usesInterfaceType(.wiredEthernet) { .wired }
                else { .other }
            Task { @MainActor [weak self] in
                guard let self, self.interface != interface else { return }
                self.interface = interface
            }
        }
        monitor.start(queue: DispatchQueue(label: "RemoteCoder.telemetry-network"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
