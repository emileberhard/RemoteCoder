import SwiftUI

struct ComposerWaveformView: View {
    let isActive: Bool
    let tint: Color
    let level: () -> Float
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.visualsVisible) private var visualsVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @State private var renderer = ComposerWaveformRenderer()

    private var isAnimating: Bool {
        isActive && scenePhase == .active && visualsVisible && !reduceMotion
    }

    var body: some View {
        let interval = energyPolicy.waveformInterval
        NativeComposerWaveform(renderer: renderer, tint: tint.opacity(isActive ? 0.95 : 0.35))
            .task(id: Playback(active: isAnimating, interval: interval)) {
                guard isAnimating else { return }
                defer { renderer.stop() }
                let clock = ContinuousClock()
                var next = clock.now
                while !Task.isCancelled {
                    renderer.append(level(), interval: interval, glides: !energyPolicy.conservesEnergy)
                    next = max(next + interval, clock.now)
                    do {
                        try await clock.sleep(until: next)
                    } catch {
                        return
                    }
                }
            }
            .accessibilityHidden(true)
    }

    private struct Playback: Equatable {
        let active: Bool
        let interval: Duration
    }
}
