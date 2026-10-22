import SwiftUI
import UIKit

@MainActor
final class TranscriptScrollHalt {
    weak var scrollView: UIScrollView?

    func stop() {
        guard let scrollView else { return }
        let pan = scrollView.panGestureRecognizer
        pan.isEnabled = false
        pan.isEnabled = true
        scrollView.stopScrollingAndZooming()
    }
}

struct TranscriptScrollHaltAnchor: UIViewRepresentable {
    let halt: TranscriptScrollHalt

    func makeUIView(context: Context) -> AnchorView { AnchorView(halt: halt) }

    func updateUIView(_ view: AnchorView, context: Context) {}

    final class AnchorView: UIView {
        private let halt: TranscriptScrollHalt

        init(halt: TranscriptScrollHalt) {
            self.halt = halt
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            halt.scrollView = sequence(first: self as UIView, next: \.superview).lazy.compactMap { $0 as? UIScrollView }.first
        }
    }
}
