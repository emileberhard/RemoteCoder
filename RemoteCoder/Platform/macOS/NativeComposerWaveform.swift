#if os(macOS)
import AppKit
import SwiftUI

struct NativeComposerWaveform: NSViewRepresentable {
    let renderer: ComposerWaveformRenderer
    let tint: Color

    func makeNSView(context: Context) -> WaveformView {
        WaveformView(renderer: renderer)
    }

    func updateNSView(_ view: WaveformView, context: Context) {
        view.color = tint.resolve(in: context.environment).cgColor
        view.needsLayout = true
    }

    final class WaveformView: NSView {
        private let renderer: ComposerWaveformRenderer
        var color = NSColor.white.cgColor

        init(renderer: ComposerWaveformRenderer) {
            self.renderer = renderer
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(renderer.layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            renderer.layout(size: bounds.size, color: color)
        }
    }
}
#endif
