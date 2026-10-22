#if os(macOS)
import SwiftUI

struct ThinkingDots: View {
    let tint: Color
    let isAnimating: Bool

    var body: some View {
        Text("...")
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}
#endif
