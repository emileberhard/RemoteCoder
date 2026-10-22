import SwiftUI

struct ContextMenuItem: Identifiable {
    let title: String
    let systemImage: String
    let perform: () -> Void

    var id: String { title }
}

struct ScrollItemMenuContent<ID: Hashable> {
    let id: ID
    let items: [ContextMenuItem]
    let preview: ControlPeekPreview
    let cornerRadius: CGFloat
}
