import SwiftUI

/// Voice Memos-style waveform; while recording in an active scene it samples on the energy
/// policy's cadence and glides at 60 Hz, stepping per sample under energy pressure.
struct ComposerWaveformView: View {
    let isActive: Bool
    let tint: Color
    let level: () -> Float
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.visualsVisible) private var visualsVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @State private var trace = WaveformTrace()

    private var isAnimating: Bool {
        isActive && scenePhase == .active && visualsVisible && !reduceMotion
    }

    private var glides: Bool { !energyPolicy.conservesEnergy }

    var body: some View {
        let interval = energyPolicy.waveformInterval
        TimelineView(.animation(minimumInterval: glides ? 1.0 / 60 : interval / .seconds(1), paused: !isAnimating)) { timeline in
            Canvas { context, size in
                let advanced = isAnimating ? trace.advance(to: timeline.date, every: interval, level: level) : 0
                let phase = glides ? advanced : 0
                let barWidth: CGFloat = 2
                let stride: CGFloat = 3
                var bars = Path()
                for (offset, sample) in trace.samples.values.reversed().enumerated() {
                    let x = size.width - (CGFloat(offset) + phase) * stride
                    if x < -stride { break }
                    let height = max(3, sample * size.height * 0.95)
                    bars.addRoundedRect(in: CGRect(x: x, y: (size.height - height) / 2,
                        width: barWidth, height: height), cornerSize: CGSize(width: 1, height: 1))
                }
                context.fill(bars, with: .color(tint.opacity(isActive ? 0.95 : 0.35)))
            }
        }
        .accessibilityHidden(true)
    }
}
