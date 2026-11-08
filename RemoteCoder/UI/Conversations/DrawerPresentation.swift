import Observation

@MainActor
@Observable
final class DrawerPresentation {
    var isOpen: Bool {
        didSet { if isOpen != oldValue { settle(resting: nil) } }
    }
    private(set) var isSettledOpen: Bool
    private(set) var isSettledClosed: Bool

    init(isOpen: Bool) {
        self.isOpen = isOpen
        isSettledOpen = isOpen
        isSettledClosed = !isOpen
    }

    func rest(open: Bool) {
        settle(resting: open == isOpen ? open : nil)
    }

    private func settle(resting: Bool?) {
        if isSettledOpen != (resting == true) { isSettledOpen = resting == true }
        if isSettledClosed != (resting == false) { isSettledClosed = resting == false }
    }
}
