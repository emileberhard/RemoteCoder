import Observation

@MainActor
@Observable
final class DrawerPresentation {
    var isOpen: Bool {
        didSet { if isOpen != oldValue { restingOpen = nil } }
    }
    private(set) var restingOpen: Bool?

    var isSettledOpen: Bool { restingOpen == true }

    init(isOpen: Bool) {
        self.isOpen = isOpen
        restingOpen = isOpen
    }

    func rest(open: Bool) {
        restingOpen = open == isOpen ? open : nil
    }
}
