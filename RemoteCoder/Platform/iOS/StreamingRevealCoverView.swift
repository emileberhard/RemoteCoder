import SwiftUI
import UIKit

struct StreamingRevealCoverView: UIViewRepresentable {
    let covers: [StreamingRevealCover]

    func makeUIView(context: Context) -> StreamingRevealCoverHost {
        StreamingRevealCoverHost()
    }

    func updateUIView(_ view: StreamingRevealCoverHost, context: Context) {
        view.layers.update(covers, color: Color.appSystemBackground.resolve(in: context.environment).cgColor)
    }

    static func dismantleUIView(_ view: StreamingRevealCoverHost, coordinator: ()) {
        view.layers.stop()
    }
}

final class StreamingRevealCoverHost: UIView {
    private(set) lazy var layers = StreamingRevealCoverLayers(host: layer) { CADisplayLink(target: $0, selector: $1) }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
