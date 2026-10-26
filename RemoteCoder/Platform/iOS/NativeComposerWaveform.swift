import SwiftUI
import UIKit

struct NativeComposerWaveform: UIViewRepresentable {
    let renderer: ComposerWaveformRenderer
    let tint: Color

    func makeUIView(context: Context) -> WaveformView {
        WaveformView(renderer: renderer)
    }

    func updateUIView(_ view: WaveformView, context: Context) {
        view.color = tint.resolve(in: context.environment).cgColor
        view.setNeedsLayout()
    }

    final class WaveformView: UIView {
        private let renderer: ComposerWaveformRenderer
        var color = UIColor.white.cgColor

        init(renderer: ComposerWaveformRenderer) {
            self.renderer = renderer
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            layer.addSublayer(renderer.layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            renderer.layout(size: bounds.size, color: color)
        }
    }
}
