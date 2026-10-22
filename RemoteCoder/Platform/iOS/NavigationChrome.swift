import SwiftUI

extension ToolbarItemPlacement {
    static var appLeading: ToolbarItemPlacement { .topBarLeading }
    static var appTrailing: ToolbarItemPlacement { .topBarTrailing }
    static var appBottom: ToolbarItemPlacement { .bottomBar }
}

extension View {
    func inlineNavigationTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }

    func clearNavigationBackground() -> some View {
        containerBackground(.clear, for: .navigation)
    }
}
