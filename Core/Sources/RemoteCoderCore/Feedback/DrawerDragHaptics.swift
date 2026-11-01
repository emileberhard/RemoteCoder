import Foundation

enum DrawerDragHaptics {
    static func event(initialOpen: Bool, open: Bool, progress: CGFloat) -> HapticEvent? {
        guard open != initialOpen, progress > 0, progress < 1 else { return nil }
        return .selection
    }
}
