#if RC_PERF_HARNESS
import SwiftUI
import UIKit

struct PerformanceReplayDrawerPublisher: UIViewRepresentable {
    let motion: DrawerMotion
    let begin: (UIView) -> Void
    let track: (CGFloat) -> Void
    let end: (CGFloat) -> Void
    let cancel: () -> Void
    let reset: () -> Void

    func makeUIView(context: Context) -> PerformanceReplayDrawerView {
        PerformanceReplayDrawerView(motion: motion, begin: begin, track: track, end: end, cancel: cancel, reset: reset)
    }

    func updateUIView(_ view: PerformanceReplayDrawerView, context: Context) {
        view.begin = begin
        view.track = track
        view.end = end
        view.cancel = cancel
        view.reset = reset
    }

    static func dismantleUIView(_ view: PerformanceReplayDrawerView, coordinator: ()) {
        PerfHarness.shared.removeDrawer(view)
    }
}

@MainActor
final class PerformanceReplayDrawerView: UIView {
    let motion: DrawerMotion
    var begin: (UIView) -> Void
    var track: (CGFloat) -> Void
    var end: (CGFloat) -> Void
    var cancel: () -> Void
    var reset: () -> Void

    init(motion: DrawerMotion, begin: @escaping (UIView) -> Void, track: @escaping (CGFloat) -> Void,
         end: @escaping (CGFloat) -> Void, cancel: @escaping () -> Void, reset: @escaping () -> Void) {
        self.motion = motion
        self.begin = begin
        self.track = track
        self.end = end
        self.cancel = cancel
        self.reset = reset
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { return nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            PerfHarness.shared.installDrawer(self)
        } else {
            PerfHarness.shared.removeDrawer(self)
        }
    }
}
#endif
