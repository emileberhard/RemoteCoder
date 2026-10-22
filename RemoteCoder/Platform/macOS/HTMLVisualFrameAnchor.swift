#if os(macOS)
import SwiftUI

@MainActor
final class HTMLVisualFrameAnchor {
    func transitionFrame(for rect: CGRect) -> HostFileTransition.Frame? { nil }
}

extension View {
    func htmlVisualFrameAnchor(_ anchor: HTMLVisualFrameAnchor) -> some View { self }
}
#endif
