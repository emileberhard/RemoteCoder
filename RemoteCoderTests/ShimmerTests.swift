import Observation
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@Suite(.serialized)
@MainActor
struct ShimmerTests {
    @Test(arguments: ShimmerGate.allCases.filter { $0 != .running })
    func closingAGateRemovesNativeMotionInsideAnAnimatedTransaction(gate: ShimmerGate) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hosted = HostedWindow(scene: scene)
        let fixture = ShimmerFixture()
        let controller = UIHostingController(rootView: ShimmerFixtureView(fixture: fixture))
        hosted.show(controller)
        defer { hosted.close() }
        controller.view.layoutIfNeeded()
        try #require(hasRepeatingGradient(controller.view.layer))

        withAnimation(.linear(duration: 10)) { fixture.gate = gate }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(!hasRepeatingGradient(controller.view.layer))
    }

    private func hasRepeatingGradient(_ layer: CALayer) -> Bool {
        if layer is CAGradientLayer,
           layer.animationKeys()?.contains(where: { key in
               (layer.animation(forKey: key)?.repeatCount ?? 0) > 0
           }) == true {
            return true
        }
        return layer.sublayers?.contains(where: hasRepeatingGradient) == true
    }
}

enum ShimmerGate: CaseIterable, Sendable {
    case running, completed, hidden, lowPower, inactive
}

@MainActor @Observable
private final class ShimmerFixture {
    var gate = ShimmerGate.running
}

private struct ShimmerFixtureView: View {
    let fixture: ShimmerFixture

    var body: some View {
        Text("Thinking")
            .shimmer(isActive: fixture.gate != .completed)
            .environment(\.scenePhase, fixture.gate == .inactive ? .inactive : .active)
            .environment(\.visualsVisible, fixture.gate != .hidden)
            .environment(\.appEnergyPolicy, AppEnergyPolicy(
                isLowPowerModeEnabled: fixture.gate == .lowPower,
                thermalState: .nominal
            ))
            .frame(width: 200, height: 80)
    }
}
