import SwiftUI

struct InlinePastedTextToken: View {
    let title: String
    let fontSize: CGFloat
    let open: @MainActor () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Image(systemName: "text.alignleft")
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .scaledFont(.system(size: fontSize))
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appContentSurface(.standard, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pasted text, \(title)")
    }
}
