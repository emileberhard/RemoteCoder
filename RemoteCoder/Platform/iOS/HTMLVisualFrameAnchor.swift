import SwiftUI
import UIKit

@MainActor
final class HTMLVisualFrameAnchor {
    private weak var view: UIView?

    func transitionFrame(for rect: CGRect) -> HostFileTransition.Frame? {
        { [weak self] in
            guard let view = self?.view, view.window != nil else { return .zero }
            return view.convert(rect, to: nil)
        }
    }

    fileprivate func attach(_ view: UIView) {
        self.view = view
    }
}

extension View {
    func htmlVisualFrameAnchor(_ anchor: HTMLVisualFrameAnchor) -> some View {
        background { HTMLVisualFrameAnchorView(anchor: anchor) }
    }
}

private struct HTMLVisualFrameAnchorView: UIViewRepresentable {
    let anchor: HTMLVisualFrameAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.attach(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.attach(view)
    }
}
