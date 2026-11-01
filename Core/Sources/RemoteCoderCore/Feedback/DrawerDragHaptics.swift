import Foundation

struct DrawerDragHaptics {
    private var initialOpen: Bool?

    mutating func begin(open: Bool) {
        initialOpen = open
    }

    mutating func release(open: Bool, progress: CGFloat) -> HapticEvent? {
        defer { cancel() }
        guard let initialOpen, open != initialOpen, progress > 0, progress < 1 else { return nil }
        return .selection
    }

    mutating func cancel() {
        initialOpen = nil
    }
}
