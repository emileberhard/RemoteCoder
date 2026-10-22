import SwiftUI

struct WindowActivity: ViewModifier {
    let workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase, initial: true) { _, phase in
            workspace.setWindowActive(window, isActive: phase == .active)
        }
    }
}

struct WindowVisibility: ViewModifier {
    @Binding var isVisible: Bool

    func body(content: Content) -> some View { content }
}

struct WindowActivations: ViewModifier {
    @Binding var count: Int

    func body(content: Content) -> some View { content }
}
