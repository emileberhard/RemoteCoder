import SwiftUI

struct ComposerWaveformView: View {
    let isActive: Bool
    let tint: Color
    let levels: () -> AsyncStream<[Float]>
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.visualsVisible) private var visualsVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @State private var renderer = ComposerWaveformRenderer()

    private var isAnimating: Bool {
        isActive && scenePhase == .active && visualsVisible && !reduceMotion
    }

    var body: some View {
        let glides = !energyPolicy.conservesEnergy
        NativeComposerWaveform(renderer: renderer, tint: tint.opacity(isActive ? 0.95 : 0.35))
            .task(id: Playback(active: isAnimating, glides: glides)) {
                guard isAnimating else { return }
                defer { renderer.stop() }
                for await batch in levels() {
                    renderer.append(batch, every: AudioLevelMeter.window, glides: glides)
                }
            }
            .accessibilityHidden(true)
    }

    private struct Playback: Equatable {
        let active: Bool
        let glides: Bool
    }
}
