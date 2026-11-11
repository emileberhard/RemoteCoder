#if os(macOS)
import SwiftUI

struct AppActionMenu<Label: View>: View {
    let title: String
    let items: [ContextMenuItem]
    @ViewBuilder let label: Label

    var body: some View {
        AppMenu(trigger: .icon) {
            ForEach(items) { item in
                Button(item.title, systemImage: item.systemImage, action: item.perform)
            }
        } label: {
            label
        }
        .accessibilityLabel(title)
    }
}
#endif
