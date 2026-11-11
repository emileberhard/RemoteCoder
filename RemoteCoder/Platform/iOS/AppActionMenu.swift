import SwiftUI
import UIKit

struct AppActionMenu<Label: View>: View {
    let title: String
    let items: [ContextMenuItem]
    @ViewBuilder let label: Label

    var body: some View {
        label
            .accessibilityHidden(true)
            .overlay { TouchDownMenuButton(title: title, items: items) }
    }
}

private struct TouchDownMenuButton: UIViewRepresentable {
    let title: String
    let items: [ContextMenuItem]
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> MenuButton { MenuButton() }

    func updateUIView(_ button: MenuButton, context: Context) {
        button.items = items
        button.accessibilityLabel = title
        button.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MenuButton, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 44, height: 44))
    }

    static func dismantleUIView(_ button: MenuButton, coordinator: ()) {
        button.items = []
    }

    final class MenuButton: UIButton {
        var items: [ContextMenuItem] = [] {
            didSet {
                guard !items.elementsEqual(oldValue, by: { $0.title == $1.title && $0.systemImage == $1.systemImage }) else { return }
                menu = UIMenu(children: items.indices.map { index in
                    UIAction(title: items[index].title, image: UIImage(systemName: items[index].systemImage)) { [weak self] _ in
                        guard let self, self.items.indices.contains(index) else { return }
                        self.items[index].perform()
                    }
                })
            }
        }

        init() {
            super.init(frame: .zero)
            showsMenuAsPrimaryAction = true
            preferredMenuElementOrder = .priority
            addAction(UIAction { [unowned self] _ in
                HapticService.shared.play(.iconPress)
                performPrimaryAction()
            }, for: .touchDown)
        }

        required init?(coder: NSCoder) { nil }
    }
}
