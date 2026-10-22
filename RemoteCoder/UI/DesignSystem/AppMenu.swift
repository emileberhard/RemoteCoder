import SwiftUI

/// The native menu, with tactile trigger styling that cannot be accidentally
/// replaced by a caller's plain style. Menu tracking and item feedback stay native.
struct AppMenu<Label: View, Content: View>: View {
    enum Trigger { case labeled, icon, toolbarItem }
    private let trigger: Trigger
    private let menu: Menu<Label, Content>

    init(trigger: Trigger = .labeled, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.trigger = trigger
        self.menu = Menu(content: content, label: label)
    }

    init(trigger: Trigger = .labeled, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label,
         primaryAction: @escaping () -> Void) {
        self.trigger = trigger
        self.menu = Menu(content: content, label: label, primaryAction: primaryAction)
    }

    var body: some View {
        switch trigger {
        case .toolbarItem:
            menu
        case .labeled, .icon:
            menu
                .menuStyle(.button)
                .buttonStyle(trigger == .icon ? AppControlHaptics.icon : AppControlHaptics.standard)
        }
    }
}
