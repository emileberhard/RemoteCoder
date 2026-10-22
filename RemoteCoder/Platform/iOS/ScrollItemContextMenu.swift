import SwiftUI
import UIKit

extension View {
    func scrollItemMenu<ID>(_ menu: ScrollItemContextMenu<ID>, content: ScrollItemMenuContent<ID>) -> some View {
        background { ScrollItemMenuAnchor(menu: menu, content: content) }
            .opacity(menu.liftedID == content.id ? 0 : 1)
    }

    func scrollItemMenuObstruction<ID>(_ menu: ScrollItemContextMenu<ID>) -> some View {
        background { ScrollItemMenuObstruction(menu: menu) }
    }
}

@Observable @MainActor
final class ScrollItemContextMenu<ID: Hashable>: NSObject, UIContextMenuInteractionDelegate {
    var liftedID: ID? { shown?.id }

    private var shown: Lift?
    @ObservationIgnored private var pending: Lift?
    @ObservationIgnored private lazy var interaction = UIContextMenuInteraction(delegate: self)
    @ObservationIgnored private let anchors = NSHashTable<ScrollItemMenuAnchor<ID>.AnchorView>.weakObjects()
    @ObservationIgnored fileprivate let obstructions = NSHashTable<UIView>.weakObjects()

    private struct Lift {
        let configuration: UIContextMenuConfiguration
        let id: ID
        weak var anchor: ScrollItemMenuAnchor<ID>.AnchorView?
        let visibleRect: CGRect
        let snapshot: UIView
        let parameters: UIPreviewParameters
    }

    fileprivate func attach(_ anchor: ScrollItemMenuAnchor<ID>.AnchorView) {
        anchors.add(anchor)
        guard let scrollView = sequence(first: anchor as UIView, next: \.superview).lazy.compactMap({ $0 as? UIScrollView }).first,
              interaction.view !== scrollView else { return }
        interaction.view?.removeInteraction(interaction)
        scrollView.addInteraction(interaction)
    }

    fileprivate func detach(_ anchor: ScrollItemMenuAnchor<ID>.AnchorView) {
        anchors.remove(anchor)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let scrollView = interaction.view as? UIScrollView, let window = scrollView.window,
              let anchor = anchors.allObjects.first(where: { $0.convert($0.bounds, to: scrollView).contains(location) })
        else { return nil }
        let pressed = anchor.convert(location, from: scrollView)
        let onScreen = anchor.bounds.intersection(scrollView.convert(scrollView.bounds, to: anchor))
        var top = onScreen.minY
        var bottom = onScreen.maxY
        for obstruction in obstructions.allObjects {
            let covered = obstruction.convert(obstruction.bounds, to: anchor)
            guard covered.intersects(onScreen) else { continue }
            if covered.midY < pressed.y { top = max(top, covered.maxY) } else { bottom = min(bottom, covered.minY) }
        }
        let visibleRect = CGRect(x: onScreen.minX, y: top, width: onScreen.width, height: max(0, bottom - top))
        guard visibleRect.contains(pressed),
              let snapshot = window.resizableSnapshotView(from: anchor.convert(visibleRect, to: window),
                                                          afterScreenUpdates: false, withCapInsets: .zero)
        else { return nil }
        let rowShape = UIBezierPath(roundedRect: anchor.bounds.offsetBy(dx: -visibleRect.minX, dy: -visibleRect.minY), cornerRadius: anchor.content.cornerRadius)
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(cgPath: rowShape.cgPath.intersection(CGPath(rect: snapshot.bounds, transform: nil)))
        let content = anchor.content
        let configuration = UIContextMenuConfiguration(identifier: nil) {
            let preview = UIHostingController(rootView: content.preview)
            preview.sizingOptions = .preferredContentSize
            return preview
        } actionProvider: { _ in
            UIMenu(children: content.items.map { item in
                UIAction(title: item.title, image: UIImage(systemName: item.systemImage)) { _ in item.perform() }
            })
        }
        pending = Lift(configuration: configuration, id: content.id, anchor: anchor,
                       visibleRect: visibleRect, snapshot: snapshot, parameters: parameters)
        return configuration
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        if let pending, pending.configuration === configuration {
            shown = pending
            self.pending = nil
        }
        guard let shown, shown.configuration === configuration else { return nil }
        return targetedPreview(of: shown, in: interaction)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        guard let shown, shown.configuration === configuration else { return nil }
        return targetedPreview(of: shown, in: interaction)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        if pending?.configuration === configuration { pending = nil }
        let settle = { [weak self] in
            guard let self, self.shown?.configuration === configuration else { return }
            self.shown = nil
        }
        if let animator { animator.addCompletion(settle) } else { settle() }
    }

    private func targetedPreview(of lift: Lift, in interaction: UIContextMenuInteraction) -> UITargetedPreview? {
        guard let container = interaction.view, let anchor = lift.anchor, anchor.window != nil, anchor.content.id == lift.id else { return nil }
        let center = anchor.convert(CGPoint(x: lift.visibleRect.midX, y: lift.visibleRect.midY), to: container)
        return UITargetedPreview(view: lift.snapshot, parameters: lift.parameters,
                                 target: UIPreviewTarget(container: container, center: center))
    }
}

struct ScrollItemMenuAnchor<ID: Hashable>: UIViewRepresentable {
    let menu: ScrollItemContextMenu<ID>
    let content: ScrollItemMenuContent<ID>

    func makeUIView(context: Context) -> AnchorView { AnchorView(menu: menu, content: content) }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.content = content
    }

    final class AnchorView: UIView {
        private let menu: ScrollItemContextMenu<ID>
        var content: ScrollItemMenuContent<ID>

        init(menu: ScrollItemContextMenu<ID>, content: ScrollItemMenuContent<ID>) {
            self.menu = menu
            self.content = content
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { menu.detach(self) } else { menu.attach(self) }
        }
    }
}

struct ScrollItemMenuObstruction<ID: Hashable>: UIViewRepresentable {
    let menu: ScrollItemContextMenu<ID>

    func makeUIView(context: Context) -> ObstructionView { ObstructionView(menu: menu) }

    func updateUIView(_ view: ObstructionView, context: Context) {}

    final class ObstructionView: UIView {
        private let menu: ScrollItemContextMenu<ID>

        init(menu: ScrollItemContextMenu<ID>) {
            self.menu = menu
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { menu.obstructions.remove(self) } else { menu.obstructions.add(self) }
        }
    }
}
