import SwiftUI

extension EnvironmentValues {
    @Entry var appEnergyPolicy = AppEnergyPolicy.current
    @Entry var surfaceVisibility = SurfaceVisibility()
    @Entry var isAttachmentDropTargeted = false
    @Entry var chromeTransitionNamespace: Namespace.ID?
    @Entry var chatImageSource: ChatImageSource?
    @Entry var interfaceScale: CGFloat = 1
}

@MainActor
@Observable
final class SurfaceVisibilityState {
    var isVisible: Bool

    init(isVisible: Bool) {
        self.isVisible = isVisible
    }
}

/// A mounted surface can be covered: the chat by its drawer or a full-screen
/// call, and the closed drawer by the chat.
struct SurfaceVisibility: Equatable {
    private let state: SurfaceVisibilityState?

    init() {
        state = nil
    }

    init(_ state: SurfaceVisibilityState) {
        self.state = state
    }

    @MainActor var isVisible: Bool { state?.isVisible ?? true }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.state === rhs.state }
}
