import SwiftUI

@MainActor
final class ScrollItemContextMenu<ID: Hashable> {}

extension View {
    func scrollItemMenuObstruction<ID>(_ menu: ScrollItemContextMenu<ID>) -> some View { self }

    func scrollItemMenu<ID>(_ menu: ScrollItemContextMenu<ID>, content: ScrollItemMenuContent<ID>) -> some View {
        contextMenu {
            ForEach(content.items) { item in
                Button(item.title, systemImage: item.systemImage, action: item.perform)
            }
        }
    }
}
