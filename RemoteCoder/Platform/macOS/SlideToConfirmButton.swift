#if os(macOS)
import SwiftUI

struct SlideToConfirmButton<Face: View>: View {
    let label: String
    let verb: String
    let symbol: String
    let tint: Color
    let identifier: String
    let action: () -> Void
    @ViewBuilder let face: () -> Face

    var body: some View {
        Button(action: action) { face() }
            .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress, pressedScale: 0.92, pressedOpacity: 0.9))
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}
#endif
