#if os(macOS)
import AppKit
import SwiftUI

struct StreamingRevealCoverView: NSViewRepresentable {
    let covers: [StreamingRevealCover]

    func makeNSView(context: Context) -> StreamingRevealCoverHost {
        StreamingRevealCoverHost()
    }

    func updateNSView(_ view: StreamingRevealCoverHost, context: Context) {
        view.layers.update(covers, color: Color.appSystemBackground.resolve(in: context.environment).cgColor)
    }

    static func dismantleNSView(_ view: StreamingRevealCoverHost, coordinator: ()) {
        view.layers.stop()
    }
}

final class StreamingRevealCoverHost: NSView {
    private let host = CALayer()
    private(set) lazy var layers = StreamingRevealCoverLayers(host: host) { [unowned self] in
        self.displayLink(target: $0, selector: $1)
    }

    init() {
        host.isGeometryFlipped = true
        super.init(frame: .zero)
        layer = host
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
