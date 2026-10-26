#if RC_PERF_HARNESS
import SwiftUI

@MainActor
struct PerformanceReplaySidebarControl {
    let owner: UUID
    let isOpen: Bool
    let toggle: () -> Void
}

struct PerformanceReplaySidebarPublisher: View {
    let window: ChatWindowModel
    let isOpen: Bool
    let toggle: () -> Void
    @State private var owner = UUID()

    var body: some View {
        window.performanceSidebar = PerformanceReplaySidebarControl(owner: owner, isOpen: isOpen, toggle: toggle)
        return Color.clear.frame(width: 0, height: 0).onDisappear {
            if window.performanceSidebar?.owner == owner { window.performanceSidebar = nil }
        }
    }
}
#endif
