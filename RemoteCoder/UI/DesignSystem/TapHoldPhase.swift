enum TapHoldPhase {
    case began, changed, ended, cancelled
}

extension TapHoldButton {
    struct AccessibilityAction {
        let name: String
        let perform: () -> Void
    }
}
