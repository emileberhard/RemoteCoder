import SwiftUI

struct GlassTapTarget: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: cornerRadius))
    }
}

extension View {
    func glassTapTarget(cornerRadius: CGFloat) -> some View {
        modifier(GlassTapTarget(cornerRadius: cornerRadius))
    }
}
