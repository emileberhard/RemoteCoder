#if os(macOS)
import SwiftUI

struct ShimmerEffect: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View { content }
}
#endif
