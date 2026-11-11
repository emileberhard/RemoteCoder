import SwiftUI

struct ForkOriginHeader: View {
    let origin: ForkOrigin
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Label(origin.label, systemImage: "arrow.triangle.branch")
                .scaledFont(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .contentShape(.capsule)
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress, pressedScale: 0.96, pressedOpacity: 0.9))
        .appGlass(.standard, in: .capsule)
        .tooltip("Open the conversation this chat was forked from")
        .accessibilityIdentifier("fork-origin")
    }
}

struct ScreenForkOriginHeader: View {
    let screen: ChatScreenModel
    let onOpen: (ConversationAddress) -> Void

    var body: some View {
        if let origin = screen.forkOrigin {
            ForkOriginHeader(origin: origin) { onOpen(origin.source) }
        }
    }
}
