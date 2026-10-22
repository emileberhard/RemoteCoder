#if os(macOS)
import SwiftUI

extension ToolbarItemPlacement {
    static var appLeading: ToolbarItemPlacement { .cancellationAction }
    static var appTrailing: ToolbarItemPlacement { .primaryAction }
    static var appBottom: ToolbarItemPlacement { .automatic }
}

extension View {
    func inlineNavigationTitle() -> some View {
        self
    }

    func clearNavigationBackground() -> some View {
        self
    }
}
#endif
