import Observation

@MainActor
@Observable
final class DrawerPresentation {
    var isOpen: Bool {
        didSet { if !isOpen { isSettledOpen = false } }
    }
    private(set) var isSettledOpen = false

    init(isOpen: Bool) {
        self.isOpen = isOpen
    }

    func rest(open: Bool) {
        isSettledOpen = open && isOpen
    }
}
